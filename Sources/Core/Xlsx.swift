import Foundation

/* xlsx → HTML 表格。
 *
 * 只做「看」需要的三件事：值算对（含公式缓存值、日期、百分比、千分位）、
 * 布局像样（列宽、行高、合并、冻结、底色、边框）、能改数字再存回去。
 * 不重算公式 —— 显示的是 Excel 上次保存时算好的缓存值，改完保存后由 Excel 重算。
 */

struct SheetRef {
    let name: String
    let path: String
    let index: Int
    let hidden: Bool
}

struct CellKey: Hashable {
    let row: Int      // 1-based
    let col: Int      // 1-based
}

/// 表格来源：xlsx 和老式 xls 都能交出一张渲染好的网格
protocol SheetSource {
    var sheets: [SheetRef] { get }
    func drawSheet(_ index: Int) -> XlsxWorkbook.Rendered
}

extension XlsxWorkbook: SheetSource {
    func drawSheet(_ index: Int) -> Rendered { render(sheetIndex: index) }
}

final class XlsxWorkbook {
    let archive: ZipArchive
    private(set) var sheets: [SheetRef] = []
    private var sharedStrings: [String] = []
    private var date1904 = false
    private var styleXFs: [XF] = []
    private var fonts: [FontInfo] = []
    private var fills: [String?] = []
    private var borders: [[String]] = []
    private var numFmtCodes: [Int: String] = [:]
    private var rels: Relationships?

    struct XF {
        var numFmtId = 0
        var fontId = 0
        var fillId = 0
        var borderId = 0
        var wrap = false
        var hAlign: String? = nil
        var vAlign: String? = nil
    }
    struct FontInfo {
        var bold = false, italic = false, underline = false, strike = false
        var sizePt: Double? = nil
        var color: String? = nil
        var name: String? = nil
    }

    /// 一次渲染的结果
    struct Rendered {
        var html = ""
        var rowCount = 0
        var colCount = 0
        var truncated = false
        var frozenRows = 0
        var frozenCols = 0
    }

    /// 单元格在 XML 里的位置，用于回写
    private var cellRanges: [CellKey: (elem: Range<Int>, vContent: Range<Int>?, type: String?, styleId: Int)] = [:]
    private var rowRanges: [Int: (range: Range<Int>, selfClosing: Bool)] = [:]
    private var sheetXML: [UInt8] = []
    private var currentSheetIndex = 0

    init?(url: URL) {
        guard let z = ZipArchive(url: url) else { return nil }
        archive = z
        loadWorkbook()
        guard !sheets.isEmpty else { return nil }
        loadSharedStrings()
        loadStyles()
    }

    // MARK: 元数据

    private func loadWorkbook() {
        guard let xml = archive.string("xl/workbook.xml") else { return }
        rels = Relationships.load(archive, path: "xl/workbook.xml")
        let sc = XMLScanner(xml)
        while let t = sc.next() {
            if t.local == "workbookpr", t.attr("date1904") == "1" { date1904 = true }
            guard t.kind == .open, t.local == "sheet" else { continue }
            let name = t.attr("name") ?? "Sheet"
            let rid = t.attr("id") ?? ""
            let state = t.attr("state") ?? "visible"
            guard let target = rels?[rid] else { continue }
            sheets.append(SheetRef(name: name, path: target,
                                   index: sheets.count, hidden: state != "visible"))
        }
        // 有些生成器不写 rels，退化到按序号找
        if sheets.isEmpty {
            var i = 1
            while let p = archive.firstName(where: { $0 == "xl/worksheets/sheet\(i).xml" }) {
                sheets.append(SheetRef(name: "Sheet\(i)", path: p, index: i - 1, hidden: false))
                i += 1
            }
        }
    }

    private func loadSharedStrings() {
        guard let xml = archive.string("xl/sharedStrings.xml") else { return }
        let sc = XMLScanner(xml)
        var cur = ""
        var inSi = false
        while let t = sc.next() {
            switch (t.kind, t.local) {
            case (.open, "si"):
                cur = ""; inSi = true
            case (.close, "si"):
                sharedStrings.append(cur); inSi = false
            case (.open, "t"):
                guard inSi else { break }
                while let nt = sc.next() {
                    if nt.kind == .close, nt.local == "t" { break }
                    if nt.kind == .text { cur += nt.text }
                }
            default: break
            }
        }
    }

    private func loadStyles() {
        guard let xml = archive.string("xl/styles.xml") else { return }
        let sc = XMLScanner(xml)
        var section = ""          // numFmts / fonts / fills / borders / cellXfs
        var font: FontInfo? = nil
        var fillColor: String? = nil
        var inFill = false
        var borderSides: [String] = []
        var curXF: XF? = nil
        var pendingNumFmtId = 0
        var pendingFontId = 0, pendingFillId = 0, pendingBorderId = 0
        var inAlignment = false

        while let t = sc.next() {
            if t.kind == .open {
                switch t.local {
                case "numfmts", "fonts", "fills", "borders", "cellxfs", "cellstylexfs":
                    section = t.local
                case "numfmt":
                    if let id = t.attr("numFmtId"), let n = Int(id), let c = t.attr("formatCode") {
                        numFmtCodes[n] = c
                    }
                case "font":
                    if section == "fonts" { font = FontInfo() }
                case "b": if font != nil { font?.bold = true }
                case "i": if font != nil { font?.italic = true }
                case "u": if font != nil, t.attr("val") != "none" { font?.underline = true }
                case "strike": if font != nil { font?.strike = true }
                case "sz":
                    if font != nil, let v = t.attr("val"), let n = Double(v) { font?.sizePt = n }
                case "color":
                    if font != nil, let rgb = t.attr("rgb"), rgb.count >= 6 {
                        font?.color = "#" + String(rgb.suffix(6))
                    }
                case "name":
                    if font != nil { font?.name = t.attr("val") }
                case "fill":
                    if section == "fills" { fillColor = nil; inFill = true }
                case "fgcolor":
                    if inFill, let rgb = t.attr("rgb"), rgb.count >= 6, !rgb.hasSuffix("FFFFFF") {
                        fillColor = "#" + String(rgb.suffix(6))
                    } else if inFill, let th = t.attr("theme"), th == "0" {
                        fillColor = nil
                    }
                case "patternfill":
                    if t.attr("patternType") == "none" { fillColor = nil }
                case "border":
                    if section == "borders" { borderSides = [] }
                case "left", "right", "top", "bottom":
                    if section == "borders", t.attr("style") != nil || t.attr("style") != "none" {
                        borderSides.append(t.local)
                    }
                case "xf":
                    pendingNumFmtId = Int(t.attr("numFmtId") ?? "0") ?? 0
                    pendingFontId = Int(t.attr("fontId") ?? "0") ?? 0
                    pendingFillId = Int(t.attr("fillId") ?? "0") ?? 0
                    pendingBorderId = Int(t.attr("borderId") ?? "0") ?? 0
                    curXF = XF(numFmtId: pendingNumFmtId, fontId: pendingFontId,
                               fillId: pendingFillId, borderId: pendingBorderId)
                case "alignment":
                    inAlignment = true
                    if section == "cellxfs", curXF != nil {
                        curXF?.wrap = t.attr("wrapText") == "1"
                        curXF?.hAlign = t.attr("horizontal")
                        curXF?.vAlign = t.attr("vertical")
                    }
                default: break
                }
            } else if t.kind == .close {
                switch t.local {
                case "fonts", "fills", "borders", "cellxfs", "numfmts":
                    section = ""
                case "font":
                    if let f = font { fonts.append(f) }
                    font = nil
                case "fill":
                    fills.append(inFill ? fillColor : nil)
                    inFill = false
                case "border":
                    borders.append(borderSides)
                case "xf":
                    if section == "cellxfs", let x = curXF { styleXFs.append(x) }
                    curXF = nil
                case "alignment":
                    inAlignment = false
                default: break
                }
            }
        }
        _ = inAlignment
    }

    // MARK: 渲染

    func render(sheetIndex: Int, maxRows: Int = 4000) -> Rendered {
        guard let sheet = sheets[safe: sheetIndex] else { return Rendered() }
        currentSheetIndex = sheetIndex
        guard let bytes = archive.rawData(sheet.path) else { return Rendered() }
        sheetXML = bytes
        cellRanges.removeAll(keepingCapacity: true)
        rowRanges.removeAll(keepingCapacity: true)

        // 先扫一遍：拿单元格、合并、列宽、冻结
        var cells: [CellKey: Cell] = [:]
        var merges: [(CellKey, CellKey)] = []
        var colWidths: [Int: Double] = [:]
        var rowHeights: [Int: Double] = [:]
        var frozenRows = 0, frozenCols = 0
        var maxRow = 0, maxCol = 0
        var totalRows = 0

        let sc = XMLScanner(bytes)
        var curRow = 0
        var curCol = 0
        var inMerge = false
        var inCols = false
        var pendingColMin = 1, pendingColMax = 1
        var pendingWidth: Double? = nil

        while let t = sc.next() {
            switch (t.kind, t.local) {
            case (.open, "pane"):
                frozenRows = Int(Double(t.attr("ySplit") ?? "0") ?? 0)
                frozenCols = Int(Double(t.attr("xSplit") ?? "0") ?? 0)
            case (.open, "col"):
                inCols = true
                pendingColMin = Int(t.attr("min") ?? "1") ?? 1
                pendingColMax = Int(t.attr("max") ?? "1") ?? 1
                if let w = t.attr("width"), let n = Double(w) { pendingWidth = n }
                if t.selfClosing {
                    if let w = pendingWidth {
                        for c in pendingColMin...max(pendingColMin, pendingColMax) { colWidths[c] = w }
                    }
                    pendingWidth = nil; inCols = false
                }
            case (.close, "col"):
                if let w = pendingWidth {
                    for c in pendingColMin...max(pendingColMin, pendingColMax) { colWidths[c] = w }
                }
                pendingWidth = nil; inCols = false
            case (.open, "row"):
                curRow = Int(t.attr("r") ?? "") ?? (curRow + 1)
                curCol = 0
                totalRows += 1
                maxRow = max(maxRow, curRow)
                if let h = t.attr("ht"), let n = Double(h) { rowHeights[curRow] = n }
                // 记录 row 元素范围，编辑空白格时要在里面插 <c>
                if t.selfClosing {
                    rowRanges[curRow] = (t.start..<t.end, true)
                } else {
                    rowRanges[curRow] = (t.start..<t.start, false)   // 结尾稍后补
                }
            case (.close, "row"):
                if var r = rowRanges[curRow], !r.selfClosing {
                    r.range = r.range.lowerBound..<t.end
                    rowRanges[curRow] = r
                }
            case (.open, "c"):
                let ref = t.attr("r")
                if let ref {
                    let (r, c) = Self.parseRef(ref)
                    curRow = r; curCol = c
                } else {
                    curCol += 1
                }
                let styleId = Int(t.attr("s") ?? "0") ?? 0
                let type = t.attr("t")
                var value = ""
                var elemEnd = t.end
                if t.selfClosing {
                    // 空但有格式的格子
                } else {
                    let elemStart = t.start
                    var vRange: Range<Int>? = nil
                    while let nt = sc.next() {
                        if nt.kind == .close, nt.local == "c" { elemEnd = nt.end; break }
                        if nt.kind == .open, nt.local == "v" {
                            var s = ""
                            var vs = -1, ve = -1
                            while let x = sc.next() {
                                if x.kind == .close, x.local == "v" {
                                    if ve < 0 { ve = x.start }
                                    break
                                }
                                if x.kind == .text {
                                    if vs < 0 { vs = x.start }
                                    s += x.text; ve = x.end
                                }
                            }
                            value = s
                            if vs >= 0 { vRange = vs..<ve }
                        } else if nt.kind == .open, nt.local == "is" {
                            // inlineStr: <is><t>文字</t></is>
                            var s = ""
                            while let x = sc.next() {
                                if x.kind == .close, x.local == "is" { break }
                                if x.kind == .open, x.local == "t" {
                                    while let y = sc.next() {
                                        if y.kind == .close, y.local == "t" { break }
                                        if y.kind == .text { s += y.text }
                                    }
                                }
                            }
                            value = s
                        } else if nt.kind == .open, nt.local == "f" {
                            // 公式本体在 <f> 里，缓存在 <v>
                        }
                    }
                    cellRanges[CellKey(row: curRow, col: curCol)] =
                        (elemStart..<elemEnd, vRange, type, styleId)
                }
                if t.selfClosing {
                    cellRanges[CellKey(row: curRow, col: curCol)] = (t.start..<t.end, nil, type, styleId)
                }

                maxCol = max(maxCol, curCol)
                if !value.isEmpty {
                    cells[CellKey(row: curRow, col: curCol)] =
                        Cell(raw: value, type: type, styleId: styleId)
                }
            case (.open, "mergecells"):
                inMerge = true
            case (.close, "mergecells"):
                inMerge = false
            case (.open, "mergecell") where inMerge:
                if let ref = t.attr("ref"), let rng = ref.split(separator: ":").first.map(String.init) {
                    let parts = ref.split(separator: ":")
                    if parts.count == 2 {
                        let a = Self.parseRef(String(parts[0]))
                        let b = Self.parseRef(String(parts[1]))
                        merges.append((CellKey(row: a.0, col: a.1), CellKey(row: b.0, col: b.1)))
                        maxRow = max(maxRow, b.0); maxCol = max(maxCol, b.1)
                    }
                    _ = rng
                }
            default: break
            }
        }
        _ = inCols

        // 合并区里的左上角以外都要留空
        var covered: Set<CellKey> = []
        var spanFor: [CellKey: (rs: Int, cs: Int)] = [:]
        for (a, b) in merges {
            let rs = b.row - a.row + 1, cs = b.col - a.col + 1
            if rs <= 0 || cs <= 0 { continue }
            spanFor[a] = (rs, cs)
            for r in a.row...b.row {
                for c in a.col...b.col where !(r == a.row && c == a.col) {
                    covered.insert(CellKey(row: r, col: c))
                }
            }
        }

        let shownRows = min(maxRow, maxRows)
        let truncated = maxRow > maxRows
        let displayMaxCol = min(max(maxCol, 1), 200)
        let displayMaxRow = max(shownRows, 1)

        var html = ""
        html.reserveCapacity(displayMaxRow * displayMaxCol * 20)

        // 列宽（字符宽 → px，Excel 的近似换算）
        func colPx(_ c: Int) -> Double {
            let w = colWidths[c] ?? 8.43
            return max(28, w * 7.2 + 6)
        }

        html += "<table class=\"sht\">"
        html += "<colgroup><col style=\"width:46px\"/>"
        for c in 1...displayMaxCol { html += "<col style=\"width:\(fmt(colPx(c)))px\"/>" }
        html += "</colgroup>"

        // 表头
        html += "<thead><tr class=\"hdr\"><th class=\"corner\"></th>"
        for c in 1...displayMaxCol {
            html += "<th data-col=\"\(c)\">\(Self.colName(c))</th>"
        }
        html += "</tr></thead><tbody>"

        for r in 1...displayMaxRow {
            let h = rowHeights[r].map { $0 * 4.0 / 3.0 }
            html += "<tr data-row=\"\(r)\"\(h.map { " style=\"height:\(fmt($0))px\"" } ?? "")>"
            html += "<th class=\"rn\">\(r)</th>"
            var c = 1
            while c <= displayMaxCol {
                let key = CellKey(row: r, col: c)
                if covered.contains(key) { c += 1; continue }
                let span = spanFor[key] ?? (1, 1)
                let cell = cells[key]
                let styleId = cell?.styleId ?? cellRanges[key]?.styleId ?? 0
                let css = cellCSS(styleId)
                let colspan = span.cs > 1 ? " colspan=\"\(span.cs)\"" : ""
                let rowspan = span.rs > 1 ? " rowspan=\"\(min(span.rs, displayMaxRow - r + 1))\"" : ""
                let editable = cellRanges[key] != nil || rowRanges[r] != nil
                let eAttr = editable ? " data-c=\"\(c)\"" : ""
                let text = cell.map { displayValue($0) } ?? ""
                let align = alignmentCSS(styleId)
                let numCls = cell.map { isNumeric($0) ? " class=\"num\"" : "" } ?? ""
                let title = text.isEmpty ? "" : " title=\"\(XMLText.escape(text))\""
                html += "<td\(numCls)\(colspan)\(rowspan)\(eAttr) data-s=\"\(styleId)\"\(css.isEmpty ? "" : " style=\"\(css)\(align)\"")\(title)>\(XMLText.escape(text))</td>"
                c += max(1, span.cs)
            }
            html += "</tr>"
        }
        html += "</tbody></table>"

        return Rendered(html: html, rowCount: maxRow, colCount: maxCol,
                        truncated: truncated, frozenRows: frozenRows, frozenCols: frozenCols)
    }

    private func cellCSS(_ styleId: Int) -> String {
        guard let xf = styleXFs[safe: styleId] else { return "" }
        var css = ""
        let font = fonts[safe: xf.fontId]
        if let f = font {
            if f.bold { css += "font-weight:700;" }
            if f.italic { css += "font-style:italic;" }
            if f.underline { css += "text-decoration:underline;" }
            if f.strike { css += "text-decoration:line-through;" }
            if let s = f.sizePt, s > 0 { css += "font-size:\(fmt(min(s, 42)))px;" }
            if let c = f.color { css += "color:\(c);" }
        }
        if let fill = fills[safe: xf.fillId], let f = fill { css += "background:\(f);" }
        if xf.wrap { css += "white-space:normal;word-break:break-word;" }
        return css
    }

    private func alignmentCSS(_ styleId: Int) -> String {
        guard let xf = styleXFs[safe: styleId] else { return "" }
        var css = ""
        switch xf.hAlign {
        case "center", "centerContinuous": css += "text-align:center;"
        case "right": css += "text-align:right;"
        case "left": css += "text-align:left;"
        case "justify": css += "text-align:justify;"
        default: break
        }
        switch xf.vAlign {
        case "top": css += "vertical-align:top;"
        case "center": css += "vertical-align:middle;"
        case "bottom": css += "vertical-align:bottom;"
        default: break
        }
        return css
    }

    private func isNumeric(_ c: Cell) -> Bool {
        guard c.type == nil || c.type == "n" else { return false }
        if let xf = styleXFs[safe: c.styleId], NumFmt.isDate(xf.numFmtId, code: numFmtCodes[xf.numFmtId]) {
            return false
        }
        return true
    }

    // MARK: 值格式化

    private struct Cell {
        let raw: String
        let type: String?
        let styleId: Int
    }

    private func displayValue(_ c: Cell) -> String {
        switch c.type {
        case "s":
            if let i = Int(c.raw), let s = sharedStrings[safe: i] { return s }
            return ""
        case "b":
            return c.raw == "1" ? "TRUE" : "FALSE"
        case "e":
            return c.raw
        case "str", "inlineStr", "d":
            return c.raw
        default:
            guard let v = Double(c.raw) else { return c.raw }
            let xf = styleXFs[safe: c.styleId] ?? XF()
            let code = numFmtCodes[xf.numFmtId] ?? NumFmt.builtin(xf.numFmtId)
            if NumFmt.isDate(xf.numFmtId, code: code) {
                return NumFmt.date(v, code: code ?? "yyyy-mm-dd", date1904: date1904)
            }
            return NumFmt.number(v, code: code, styleId: xf.numFmtId)
        }
    }

    // MARK: 编辑回写

    /// 修改一个单元格。返回重新打包后的文件；失败返回 nil。
    func applyCell(sheet sheetIndex: Int, row: Int, col: Int, text: String) -> Data? {
        guard sheetIndex == currentSheetIndex, !sheetXML.isEmpty else { return nil }
        let key = CellKey(row: row, col: col)
        var bytes = sheetXML
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let info = cellRanges[key] {
            // 已存在的格子：替换 <v> 内容，或改造成 inlineStr
            let isNumber = Double(trimmed) != nil && !trimmed.isEmpty
            if let v = info.vContent, info.type == nil || info.type == "n" {
                if isNumber {
                    bytes.replaceSubrange(v, with: Array(trimmed.utf8))
                    return repack(bytes)
                }
            }
            if let v = info.vContent, info.type == "s" || info.type == "str" || info.type == "inlineStr" {
                // 共享字符串/公式串：改成 inlineStr 更安全（不动 sharedStrings 表）
                let repl = "<is><t xml:space=\"preserve\">\(XMLText.escape(text))</t></is>"
                var e = bytes
                e.replaceSubrange(v, with: Array(repl.utf8))
                // 去掉可能残留的 t="s"（改成 inlineStr 需要一个一致的 t 属性）
                e = replaceTypeAttr(e, elemRange: info.elem, newType: isNumber ? nil : "inlineStr")
                return repack(e)
            }
            // 没有 <v>（空格式格）：整格重建
            let rebuilt = cellXML(row: row, col: col, text: trimmed, num: isNumber)
            bytes.replaceSubrange(info.elem, with: Array(rebuilt.utf8))
            return repack(bytes)
        }

        // 不存在的格子：插到该行末尾
        guard let rr = rowRanges[row], !rr.selfClosing else { return nil }
        let isNumber = Double(trimmed) != nil && !trimmed.isEmpty
        let xml = cellXML(row: row, col: col, text: trimmed, num: isNumber)
        // 插在 </row> 之前
        let insertAt = max(rr.range.lowerBound, rr.range.upperBound - 6)
        bytes.insert(contentsOf: Array(xml.utf8), at: insertAt)
        return repack(bytes)
    }

    private func cellXML(row: Int, col: Int, text: String, num: Bool) -> String {
        let ref = "\(Self.colName(col))\(row)"
        if num {
            return "<c r=\"\(ref)\"><v>\(text)</v></c>"
        }
        return "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(XMLText.escape(text))</t></is></c>"
    }

    /// 把 <c t="s"> 的 t 属性改写掉（没有就加上）
    private func replaceTypeAttr(_ bytes: [UInt8], elemRange: Range<Int>, newType: String?) -> [UInt8] {
        var head = String(decoding: bytes[elemRange], as: UTF8.self)
        guard let gt = head.firstIndex(of: ">") else { return bytes }
        var tag = String(head[head.startIndex..<gt])
        // 去掉旧的 t="..."
        if let r = tag.range(of: " t=\"[^\"]*\"", options: .regularExpression) {
            tag.replaceSubrange(r, with: "")
        }
        if let nt = newType { tag += " t=\"\(nt)\"" }
        head = tag + head[gt...]
        var out = bytes
        out.replaceSubrange(elemRange, with: Array(head.utf8))
        return out
    }

    private func repack(_ bytes: [UInt8]) -> Data {
        guard let sheet = sheets[safe: currentSheetIndex] else { return Data() }
        var items: [ZipWriter.Item] = []
        for e in archive.entries {
            if e.name == sheet.path {
                items.append(.init(name: e.name, bytes: bytes))
            } else if let d = archive.rawData(e.name) {
                items.append(.init(name: e.name, bytes: d))
            }
        }
        return ZipWriter.build(items)
    }

    // MARK: 工具

    static func colName(_ n: Int) -> String {
        var n = n, s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(65 + r)!) + s
            n = (n - 1) / 26
        }
        return s.isEmpty ? "A" : s
    }

    static func parseRef(_ ref: String) -> (Int, Int) {
        var col = 0, row = 0
        for ch in ref.uppercased() {
            if ch >= "A" && ch <= "Z" {
                col = col * 26 + (Int(ch.asciiValue!) - 64)
            } else if ch >= "0" && ch <= "9" {
                row = row * 10 + (Int(ch.asciiValue!) - 48)
            }
        }
        return (max(row, 1), max(col, 1))
    }
}

// MARK: - 数字格式

enum NumFmt {
    /// 内建格式码（ECMA-376 第 1 部分 18.8.30）
    static func builtin(_ id: Int) -> String? {
        switch id {
        case 0: return nil
        case 1: return "0"
        case 2: return "0.00"
        case 3: return "#,##0"
        case 4: return "#,##0.00"
        case 9: return "0%"
        case 10: return "0.00%"
        case 11: return "0.00E+00"
        case 12: return "# ?/?"
        case 13: return "# ??/??"
        case 14: return "m/d/yy"
        case 15: return "d-mmm-yy"
        case 16: return "d-mmm"
        case 17: return "mmm-yy"
        case 18: return "h:mm AM/PM"
        case 19: return "h:mm:ss AM/PM"
        case 20: return "h:mm"
        case 21: return "h:mm:ss"
        case 22: return "m/d/yy h:mm"
        case 37: return "#,##0 ;(#,##0)"
        case 38: return "#,##0 ;[Red](#,##0)"
        case 39: return "#,##0.00;(#,##0.00)"
        case 40: return "#,##0.00;[Red](#,##0.00)"
        case 45: return "mm:ss"
        case 46: return "[h]:mm:ss"
        case 47: return "mmss.0"
        case 48: return "##0.0E+0"
        case 49: return "@"
        default: return nil
        }
    }

    /// 是否日期/时间格式
    static func isDate(_ id: Int, code: String?) -> Bool {
        if (14...22).contains(id) || (45...47).contains(id) { return true }
        guard let code, !code.isEmpty else { return false }
        // 去掉引号里的字面量、[Red] 之类、转义字符
        var s = ""
        var inQuote = false
        for ch in code {
            if ch == "\"" { inQuote.toggle(); continue }
            if inQuote { continue }
            if ch == "[" || ch == "]" { continue }
            s.append(ch)
        }
        s = s.replacingOccurrences(of: "\\", with: "")
        let lower = s.lowercased()
        if lower.contains("general") || lower.contains("@") { return false }
        // 有 y/d/h/s（或 m 但不像 0.00m 这种）
        if lower.contains("y") || lower.contains("d") { return true }
        if lower.contains("h") || lower.contains("s") { return true }
        return false
    }

    static func number(_ v: Double, code: String?, styleId: Int) -> String {
        guard let code, !code.isEmpty, code != "General" else {
            return trimGeneral(v)
        }
        if code == "@" { return trimGeneral(v) }
        // 分号分段：正;负;零;文本
        let segs = code.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let seg: String
        if v < 0 && segs.count > 1 { seg = segs[1] }
        else if v == 0 && segs.count > 2 { seg = segs[2] }
        else { seg = segs.first ?? code }

        let pct = seg.contains("%")
        let value = pct ? v * 100 : v
        let abs = Swift.abs(value)

        // 字面量处理：引号内原样保留，其余符号解析
        var literals: [String] = []
        var skeleton = ""
        var inQuote = false
        for ch in seg {
            if ch == "\"" { inQuote.toggle(); continue }
            if inQuote { skeleton.append("\u{1}\(literals.count)\u{1}"); literals.append(String(ch)); continue }
            skeleton.append(ch)
        }
        // [Red] 这类颜色标记去掉
        skeleton = skeleton.replacingOccurrences(of: "\\[.*?\\]", with: "", options: .regularExpression)
        skeleton = skeleton.replacingOccurrences(of: "\\\\(.)", with: "$1", options: .regularExpression)

        if skeleton.contains("E+") || skeleton.contains("E-") {
            let d = String(format: "%.2e", abs)
            return (v < 0 ? "-" : "") + d + (pct ? "%" : "")
        }

        // 小数位数 & 千分位
        let dotIdx = skeleton.firstIndex(of: ".")
        var decimals = 0
        if let d = dotIdx {
            let frac = skeleton[skeleton.index(after: d)...]
            decimals = frac.filter { $0 == "0" || $0 == "#" }.count
        }
        let intPart: String = dotIdx.map { String(skeleton[..<$0]) } ?? skeleton
        let thousands = intPart.contains(",") && intPart.contains("#")

        var s = group(abs, decimals: decimals, thousands: thousands)
        if value < 0 && segs.count < 2 { s = "-" + s }

        // 把数字塞回骨架的位置
        if let d = dotIdx {
            let suffix = String(skeleton[skeleton.index(after: d)...])
                .replacingOccurrences(of: "0", with: "")
                .replacingOccurrences(of: "#", with: "")
            let prefix = String(intPart)
                .replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "0", with: "")
            s = unescapeLiterals(prefix, literals) + s + unescapeLiterals(suffix, literals)
        } else {
            let suffix = skeleton.replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "0", with: "")
            s = s + unescapeLiterals(suffix, literals)
        }
        if pct && !s.contains("%") { s += "%" }

        // 处理 (1,234) 负数括号形式
        if segs.count > 1 && segs[1].contains("(") && v < 0 {
            s = "(" + s.replacingOccurrences(of: "-", with: "") + ")"
        }
        return s
    }

    private static func unescapeLiterals(_ s: String, _ literals: [String]) -> String {
        var out = s
        for (i, lit) in literals.enumerated() {
            out = out.replacingOccurrences(of: "\u{1}\(i)\u{1}", with: lit)
        }
        // 残留的占位符直接丢掉
        out = out.replacingOccurrences(of: "[\u{1}][0-9]+[\u{1}]", with: "", options: .regularExpression)
        return out
    }

    private static func group(_ v: Double, decimals: Int, thousands: Bool) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.usesGroupingSeparator = thousands
        fmt.groupingSeparator = ","
        fmt.decimalSeparator = "."
        fmt.minimumFractionDigits = decimals
        fmt.maximumFractionDigits = decimals
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: NSNumber(value: v)) ?? String(v)
    }

    static func trimGeneral(_ v: Double) -> String {
        if v == v.rounded() && Swift.abs(v) < 1e15 {
            return String(Int64(v))
        }
        var s = String(format: "%.10g", v)
        if s.contains("e") {
            s = String(format: "%.4f", v)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    /// 序列号 → 日期字符串
    static func date(_ serial: Double, code: String, date1904: Bool) -> String {
        let base = date1904 ? 24107.0 : 25569.0
        let secs = (serial - base) * 86400.0
        let d = Date(timeIntervalSince1970: secs)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: d)

        let hasTime = code.lowercased().contains("h") || code.lowercased().contains("s")
        let hasDate = code.lowercased().contains("y") || code.lowercased().contains("d")
        let m = c.minute ?? 0, sec = c.second ?? 0, h = c.hour ?? 0

        if hasDate && !hasTime {
            return dateByPattern(code, c: c)
        }
        if hasTime && !hasDate {
            let use12 = code.uppercased().contains("AM/PM")
            if use12 {
                let h12 = h % 12 == 0 ? 12 : h % 12
                let ap = h < 12 ? "AM" : "PM"
                return String(format: "%d:%02d", h12, m) + (code.contains("ss") ? String(format: ":%.2d", sec) : "") + " " + ap
            }
            return String(format: "%02d:%02d", h, m) + (code.contains("ss") ? String(format: ":%.2d", sec) : "")
        }
        // 带时间的日期
        let dateStr = dateByPattern(code, c: c)
        let use12 = code.uppercased().contains("AM/PM")
        let timeStr = use12
            ? String(format: "%d:%02d %@", h % 12 == 0 ? 12 : h % 12, m, h < 12 ? "AM" : "PM")
            : String(format: "%02d:%02d", h, m)
        return dateStr + " " + timeStr
    }

    private static func dateByPattern(_ code: String, c: DateComponents) -> String {
        var out = ""
        var i = code.startIndex
        let chars = Array(code)
        var k = 0
        let monthsCN = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12"]
        let monthsEN = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let weekEN = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

        func run(_ ch: Character) -> Int {
            var n = 0
            while k < chars.count, chars[k] == ch { n += 1; k += 1 }
            return n
        }

        _ = i
        while k < chars.count {
            let ch = chars[k]
            switch ch {
            case "y", "Y":
                let n = run(ch)
                let year = c.year ?? 2024
                out += n <= 2 ? String(format: "%02d", year % 100) : String(year)
            case "m", "M":
                // m 紧跟 h/s 时是分钟
                let n = run(ch)
                let next = k < chars.count ? chars[k] : " "
                if n <= 2 && (String(next).lowercased() == "h" || String(next).lowercased() == "s") {
                    out += String(format: "%02d", c.minute ?? 0)
                } else if n >= 4 {
                    out += monthsEN[max(0, (c.month ?? 1) - 1)]
                } else if n == 3 {
                    out += monthsEN[max(0, (c.month ?? 1) - 1)]
                } else if n == 2 {
                    out += String(format: "%02d", c.month ?? 1)
                } else {
                    out += monthsCN[max(0, (c.month ?? 1) - 1)]
                }
            case "d", "D":
                let n = run(ch)
                if n >= 4 {
                    out += weekEN[max(0, min(6, (c.weekday ?? 1) - 1))]
                } else if n == 3 {
                    out += String(weekEN[max(0, min(6, (c.weekday ?? 1) - 1))].prefix(3))
                } else if n == 2 {
                    out += String(format: "%02d", c.day ?? 1)
                } else {
                    out += String(c.day ?? 1)
                }
            case "h", "H":
                let n = run(ch)
                let hh = c.hour ?? 0
                out += n == 2 ? String(format: "%02d", hh) : String(hh)
            case "s", "S":
                let n = run(ch)
                out += n == 2 ? String(format: "%02d", c.second ?? 0) : String(c.second ?? 0)
            case "\"":
                k += 1
                while k < chars.count, chars[k] != "\"" { out.append(chars[k]); k += 1 }
                k += 1
            case "\\":
                k += 1
                if k < chars.count { out.append(chars[k]); k += 1 }
            case "a", "A":
                // AM/PM
                let rest = String(chars[k...]).uppercased()
                if rest.hasPrefix("AM/PM") {
                    out += (c.hour ?? 0) < 12 ? "AM" : "PM"
                    k += 5
                } else {
                    out.append(ch); k += 1
                }
            case "[":
                while k < chars.count, chars[k] != "]" { k += 1 }
                k += 1
                // [h] 表示累计小时，这里退化成小时
                if code.contains("[h]") { out += String(c.hour ?? 0) }
            default:
                out.append(ch); k += 1
            }
        }
        return out
    }
}
