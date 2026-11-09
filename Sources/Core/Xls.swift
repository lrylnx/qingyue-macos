import Foundation

/* .xls / .et（Excel 97-2003 与 WPS 表格）读取。
 *
 * 数据在 CFB 里的 "Workbook" 流中，是一串「记录」：每条 4 字节头（id + 长度）+ 负载。
 * 前一段是工作簿全局区（共享字符串表、样式、字体、格式码），后面每张表各从
 * BOUNDSHEET 记下的偏移处开始，以 BOF 起、EOF 止。
 *
 * 只读：老格式的写回需要完整重排记录流和 FAT 链，收益远小于风险，先不做。
 */

final class XlsWorkbook {
    private(set) var sheets: [SheetRef] = []
    private(set) var path: String = ""

    private let stream: [UInt8]
    private var sst: [String] = []
    private var xfs: [XF] = []
    private var fonts: [FontDef] = []
    private var formats: [Int: String] = [:]
    private var palette: [Int: String] = [:]
    private var date1904 = false
    private var biff8 = true
    private var codepage: UInt16 = 1200

    // MARK: 模型

    struct XF {
        var fontId = 0
        var numFmtId = 0
        var bold = false, italic = false, underline = false, strike = false
        var sizePt: Double? = nil
        var color: String? = nil
        var fill: String? = nil
        var hAlign: String? = nil
        var vAlign: String? = nil
        var wrap = false
    }

    struct FontDef {
        var heightTwips: UInt16 = 200
        var flags: UInt16 = 0
        var colorIndex: UInt16 = 0x7FFF
        var name: String = ""
    }

    private struct Cell {
        var text: String
        var numeric: Bool
        var style: Int
    }

    // MARK: 打开

    init?(url: URL) {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        self.path = url.path
        guard let cfb = CFB([UInt8](raw)),
              let wb = cfb.firstStream(among: ["Workbook", "Book"]) else { return nil }
        stream = wb
        guard parseGlobals() else { return nil }
        guard !sheets.isEmpty else { return nil }
    }

    convenience init?(data: Data, path: String = "") {
        guard let cfb = CFB([UInt8](data)),
              let wb = cfb.firstStream(among: ["Workbook", "Book"]) else { return nil }
        self.init(stream: wb, path: path)
    }

    private init?(stream wb: [UInt8], path: String) {
        self.path = path
        stream = wb
        guard parseGlobals() else { return nil }
        guard !sheets.isEmpty else { return nil }
    }

    // MARK: 全局区

    private func parseGlobals() -> Bool {
        var p = 0
        var sawBOF = false
        while p + 4 <= stream.count {
            let id = stream.le16(p)
            let len = Int(stream.le16(p + 2))
            let body = p + 4
            guard body + len <= stream.count else { break }

            switch id {
            case 0x0809:   // BOF
                if !sawBOF {
                    sawBOF = true
                    let ver = stream.le16(body)
                    if ver != 0x0600 { biff8 = false }
                    let dt = stream.le16(body + 2)
                    // 只处理工作簿全局区，工作表在 globals 之后单独解析
                    if dt != 0x0005 { return true }
                }
            case 0x0042:   // CODEPAGE
                codepage = stream.le16(body)
            case 0x0022:   // DATEMODE
                date1904 = stream.le16(body) == 1
            case 0x0085:   // BOUNDSHEET
                addBoundSheet(body, len: len)
            case 0x00FC:   // SST
                var chunks: [[UInt8]] = [stream.slice(body, len)]
                var q = body + len
                while q + 4 <= stream.count, stream.le16(q) == 0x003C {
                    let clen = Int(stream.le16(q + 2))
                    chunks.append(stream.slice(q + 4, clen))
                    q += 4 + clen
                }
                parseSST(chunks)
                p = q
                continue
            case 0x0031:   // FONT
                addFont(body, len: len)
            case 0x041E:   // FORMAT（自定义数字格式码）
                let ifmt = Int(stream.le16(body))
                if let s = readUnicodeString(body + 2, width: 2) {
                    formats[ifmt] = s
                }
            case 0x00E0:   // XF
                addXF(body, len: len)
            case 0x0092:   // PALETTE
                let n = Int(stream.le16(body))
                for i in 0..<n {
                    let off = body + 2 + i * 4
                    guard off + 4 <= stream.count else { break }
                    let r = stream[off + 1], g = stream[off + 2], b = stream[off + 3]
                    palette[8 + i] = String(format: "#%02X%02X%02X", r, g, b)
                }
            case 0x000A:   // EOF（全局区结束）
                return true
            case 0x0009:   // 无 BOF 的怪文件
                if !sawBOF { return false }
            default:
                break
            }
            p = body + len
        }
        return sawBOF
    }

    private func addBoundSheet(_ body: Int, len: Int) {
        guard len >= 8 else { return }
        let offset = Int(stream.le32(body))
        let visibility = stream[body + 4]
        let type = stream[body + 5]
        guard type == 0 else { return }      // 图表/VB 模块不当作工作表
        guard let name = readShortUnicodeString(body + 6, limit: body + len) else { return }
        sheets.append(SheetRef(name: name.isEmpty ? "Sheet\(sheets.count + 1)" : name,
                               path: String(offset),
                               index: sheets.count,
                               hidden: visibility != 0))
    }

    private func addFont(_ body: Int, len: Int) {
        var f = FontDef()
        guard len >= 15 else { return }
        f.heightTwips = stream.le16(body)
        f.flags = stream.le16(body + 2)
        f.colorIndex = stream.le16(body + 4)
        if let n = readShortUnicodeString(body + 14, limit: body + len) { f.name = n }
        fonts.append(f)
    }

    private func addXF(_ body: Int, len: Int) {
        var x = XF()
        guard len >= 16 else { return }
        x.fontId = Int(stream.le16(body))
        x.numFmtId = Int(stream.le16(body + 2))

        let align = stream[body + 6]
        let hor = align & 0x07
        let vert = (align >> 4) & 0x07
        x.wrap = (align & 0x08) != 0
        switch hor {
        case 1: x.hAlign = "left"
        case 2: x.hAlign = "center"
        case 3: x.hAlign = "right"
        case 4: x.hAlign = "justify"
        case 5: x.hAlign = "justify"
        case 6: x.hAlign = "center"
        default: break
        }
        switch vert {
        case 0: x.vAlign = "top"
        case 1: x.vAlign = "middle"
        case 2: x.vAlign = "bottom"
        default: break
        }

        // 字体属性（BIFF8 的 XF 不带字体细节，要去 FONT 表查）
        if let f = fonts[safe: x.fontId] {
            x.bold = (f.flags & 0x01) != 0
            x.italic = (f.flags & 0x02) != 0
            x.underline = (f.flags & 0x04) != 0
            x.strike = (f.flags & 0x08) != 0
            let pt = Double(f.heightTwips) / 20.0
            if pt > 0 { x.sizePt = pt }
            if f.colorIndex != 0x7FFF { x.color = color(f.colorIndex) }
        }

        // 底纹：offset 16-17 是前景/背景色索引，18-19 含填充图案
        if len >= 20 {
            let used = stream[body + 9]
            if used & 0x40 != 0 {
                let pattern = Int(stream.le16(body + 18) & 0x7F)
                let fg = Int(stream.le16(body + 16) & 0x7F)
                if pattern > 0, fg > 0, fg < 0x40 || fg >= 8 {
                    x.fill = color(UInt16(fg))
                }
            }
            // 边框、旋转、缩进：暂时不用，表头底色与字号已经够读
        }
        xfs.append(x)
    }

    private func color(_ index: UInt16) -> String? {
        if let p = palette[Int(index)] { return p }
        return XlsWorkbook.defaultPalette[Int(index)]
    }

    /// BIFF8 默认调色板（索引 8 起）。只取常用的前 56 个。
    private static let defaultPalette: [Int: String] = {
        let hex = [
            "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
            "800000", "008000", "000080", "808000", "800080", "008080", "C0C0C0", "808080",
            "9999FF", "993366", "FFFFCC", "CCFFFF", "660066", "FF8080", "0066CC", "CCCCFF",
            "000080", "FF00FF", "FFFF00", "00FFFF", "800080", "800000", "008080", "0000FF",
            "00CCFF", "CCFFFF", "CCFFCC", "FFFF99", "99CCFF", "FF99CC", "CC99FF", "FFCC99",
            "3366FF", "33CCCC", "99CC00", "FFCC00", "FF9900", "FF6600", "666699", "969696",
            "003366", "339966", "003300", "333300", "993300", "993366", "333399", "333333",
        ]
        var map: [Int: String] = [:]
        for (i, h) in hex.enumerated() { map[8 + i] = "#" + h }
        return map
    }()

    // MARK: 字符串

    /// ShortXLUnicodeString：1 字节长度 + 1 字节标志（bit0 = 双字节）
    private func readShortUnicodeString(_ at: Int, limit: Int) -> String? {
        guard at + 1 < stream.count else { return nil }
        let cch = Int(stream[at])
        guard at + 2 <= stream.count else { return nil }
        if !biff8 {
            let end = min(stream.count, at + 1 + cch)
            return decodeBytes(Array(stream[(at + 1)..<end]))
        }
        let wide = (stream[at + 1] & 0x01) != 0
        let start = at + 2
        let need = wide ? cch * 2 : cch
        guard min(limit, stream.count) >= start + need else { return nil }
        if wide {
            return String(decoding: (0..<cch).map { stream.le16(start + $0 * 2) }, as: UTF16.self)
        }
        return decodeBytes(Array(stream[start..<(start + cch)]))
    }

    /// XLUnicodeString：2 字节长度 + 1 字节标志
    private func readUnicodeString(_ at: Int, width: Int) -> String? {
        guard at + width < stream.count else { return nil }
        let cch = width == 2 ? Int(stream.le16(at)) : Int(stream[at])
        let flagAt = at + width
        guard flagAt < stream.count else { return nil }
        let wide = (stream[flagAt] & 0x01) != 0
        let start = flagAt + 1
        let need = wide ? cch * 2 : cch
        guard stream.count >= start + need else { return nil }
        if wide {
            return String(decoding: (0..<cch).map { stream.le16(start + $0 * 2) }, as: UTF16.self)
        }
        return decodeBytes(Array(stream[start..<(start + cch)]))
    }

    private func decodeBytes(_ b: [UInt8]) -> String {
        // 中文 Excel 常见 GBK(936)；先按 GB18030 试，失败退回 Latin1
        if codepage == 936 || codepage == 0 {
            if let s = String(data: Data(b), encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))), !s.isEmpty {
                return s
            }
        }
        if let s = String(data: Data(b), encoding: .windowsCP1252), !s.isEmpty { return s }
        return String(decoding: b, as: UTF8.self)
    }

    // MARK: 共享字符串表

    private func parseSST(_ chunks: [[UInt8]]) {
        let total = Int(chunks.first?.le32(4) ?? 0)
        var r = SSTReader(chunks)
        r.pos = 8
        var i = 0
        while i < total {
            guard let cch = r.u16() else { break }
            guard let flags = r.u8() else { break }
            var wide = flags & 0x01 != 0
            let ext = flags & 0x04 != 0
            let rich = flags & 0x08 != 0
            var richRuns = 0
            var extSize = 0
            if rich, let n = r.u16() { richRuns = Int(n) }
            if ext, let n = r.u32() { extSize = Int(n) }

            var units: [UInt16] = []
            units.reserveCapacity(Int(cch))
            var left = Int(cch)
            while left > 0 {
                if r.atRecordEnd {
                    guard r.nextRecord() else { break }
                    // 续接的字符串数据开头会再来一个标志字节
                    guard let f2 = r.u8() else { break }
                    wide = f2 & 0x01 != 0
                }
                let take = min(left, r.remainingUnits(wide: wide))
                if take <= 0 {
                    if r.nextRecord() {
                        guard let f2 = r.u8() else { break }
                        wide = f2 & 0x01 != 0
                        continue
                    }
                    break
                }
                r.readUnits(take, wide: wide, into: &units)
                left -= take
            }
            if richRuns > 0 { r.skip(richRuns * 4) }
            if extSize > 0 { r.skip(extSize) }
            sst.append(String(decoding: units, as: UTF16.self))
            i += 1
        }
    }

    // MARK: 单表解析

    func drawSheet(_ index: Int) -> XlsxWorkbook.Rendered {
        guard let ref = sheets[safe: index], let offset = Int(ref.path) else { return XlsxWorkbook.Rendered() }
        return parseSheet(at: offset)
    }

    private func parseSheet(at offset: Int) -> XlsxWorkbook.Rendered {
        let debug = ProcessInfo.processInfo.environment["QY_DEBUG"] != nil
        if debug {
            FileHandle.standardError.write("XlsDebug: xfs=\(xfs.count) fonts=\(fonts.count) formats=\(formats.count) sst=\(sst.count) biff8=\(biff8) sheets=\(sheets.count)\n".data(using: .utf8) ?? Data())
        }
        var p = offset
        var cells: [CellKey: Cell] = [:]
        var merges: [(CellKey, CellKey)] = []
        var colWidths: [Int: Double] = [:]
        var rowHeights: [Int: Double] = [:]
        var maxRow = 0, maxCol = 0
        var pendingStringCell: CellKey? = nil
        var frozenRows = 0
        var colFirst = 0

        while p + 4 <= stream.count {
            let id = stream.le16(p)
            let len = Int(stream.le16(p + 2))
            let body = p + 4
            guard body + len <= stream.count else { break }
            if id == 0x000A { break }        // EOF

            switch id {
            case 0x0200:   // DIMENSIONS
                if len >= 14 {
                    maxRow = max(maxRow, Int(stream.le32(body + 4)))
                    maxCol = max(maxCol, Int(stream.le16(body + 10)))
                }
            case 0x00FD:   // LABELSST
                if len >= 10 {
                    let r = Int(stream.le16(body)), c = Int(stream.le16(body + 2))
                    let xf = Int(stream.le16(body + 4))
                    let idx = Int(stream.le32(body + 6))
                    put(&cells, r, c, Cell(text: sst[safe: idx] ?? "", numeric: false, style: xf))
                }
            case 0x0204:   // LABEL
                if len >= 8 {
                    let r = Int(stream.le16(body)), c = Int(stream.le16(body + 2))
                    let xf = Int(stream.le16(body + 4))
                    let s = readUnicodeString(body + 6, width: biff8 ? 2 : 1) ?? ""
                    put(&cells, r, c, Cell(text: s, numeric: false, style: xf))
                }
            case 0x00D6:   // RSTRING（带格式串的 LABEL）
                if len >= 8 {
                    let r = Int(stream.le16(body)), c = Int(stream.le16(body + 2))
                    let xf = Int(stream.le16(body + 4))
                    let s = readUnicodeString(body + 6, width: biff8 ? 2 : 1) ?? ""
                    put(&cells, r, c, Cell(text: s, numeric: false, style: xf))
                }
            case 0x0203:   // NUMBER
                if len >= 14 {
                    let r = Int(stream.le16(body)), c = Int(stream.le16(body + 2))
                    let xf = Int(stream.le16(body + 4))
                    put(&cells, r, c, Cell(text: numberText(stream.le64(body + 6), xf: xf),
                                           numeric: true, style: xf))
                }
            case 0x027E:   // RK
                if len >= 10 {
                    let r = Int(stream.le16(body)), c = Int(stream.le16(body + 2))
                    let xf = Int(stream.le16(body + 4))
                    let v = rkValue(stream.le32(body + 6))
                    put(&cells, r, c, Cell(text: numberText(v.bitPattern, xf: xf), numeric: true, style: xf))
                }
            case 0x00BD:   // MULRK
                if len >= 6 {
                    let r = Int(stream.le16(body))
                    let first = Int(stream.le16(body + 2))
                    let n = (len - 6) / 6
                    for i in 0..<n {
                        let off = body + 4 + i * 6
                        let xf = Int(stream.le16(off))
                        let v = rkValue(stream.le32(off + 2))
                        put(&cells, r, first + i,
                            Cell(text: numberText(v.bitPattern, xf: xf), numeric: true, style: xf))
                    }
                }
            case 0x0205:   // BOOLERR
                if len >= 8 {
                    let r = Int(stream.le16(body)), c = Int(stream.le16(body + 2))
                    let xf = Int(stream.le16(body + 4))
                    let isErr = stream[body + 7] != 0
                    let v = stream[body + 6]
                    let text = isErr ? Self.errorText(v) : (v != 0 ? "TRUE" : "FALSE")
                    put(&cells, r, c, Cell(text: text, numeric: isErr, style: xf))
                }
            case 0x0006:   // FORMULA（显示缓存结果，不重算）
                if len >= 20 {
                    let r = Int(stream.le16(body)), c = Int(stream.le16(body + 2))
                    let xf = Int(stream.le16(body + 4))
                    let res = stream.slice(body + 6, 8)
                    if res.count == 8, res.le16(6) == 0xFFFF {
                        let kind = res[0]
                        switch kind {
                        case 0:
                            pendingStringCell = CellKey(row: r, col: c)
                            put(&cells, r, c, Cell(text: "", numeric: false, style: xf))
                        case 1:
                            put(&cells, r, c, Cell(text: res[2] != 0 ? "TRUE" : "FALSE", numeric: false, style: xf))
                        case 2:
                            put(&cells, r, c, Cell(text: Self.errorText(res[2]), numeric: true, style: xf))
                        default:
                            put(&cells, r, c, Cell(text: "", numeric: false, style: xf))
                        }
                    } else if res.count == 8 {
                        let d = Double(bitPattern: res.le64(0))
                        put(&cells, r, c, Cell(text: numberText(d.bitPattern, xf: xf), numeric: true, style: xf))
                    }
                }
            case 0x0207:   // STRING（公式的字符串结果）
                if let key = pendingStringCell,
                   let s = readUnicodeString(body, width: biff8 ? 2 : 1) {
                    cells[key]?.text = s
                    cells[key]?.numeric = false
                }
                pendingStringCell = nil
            case 0x0208:   // ROW
                if len >= 16 {
                    let r = Int(stream.le16(body))
                    let h = Double(stream.le16(body + 6)) / 20.0 * 4.0 / 3.0
                    if h > 0 { rowHeights[r + 1] = h }
                }
            case 0x007D:   // COLINFO
                if len >= 8 {
                    let c1 = Int(stream.le16(body))
                    let c2 = Int(stream.le16(body + 2))
                    let w = Double(stream.le16(body + 4)) / 256.0
                    if w > 0 {
                        for c in c1...max(c1, c2) where c < 256 { colWidths[c + 1] = w }
                    }
                }
            case 0x00E5:   // MERGEDCELLS
                if len >= 2 {
                    let n = Int(stream.le16(body))
                    for i in 0..<n {
                        let off = body + 2 + i * 8
                        guard off + 8 <= stream.count else { break }
                        let r1 = Int(stream.le16(off)), r2 = Int(stream.le16(off + 2))
                        let c1 = Int(stream.le16(off + 4)), c2 = Int(stream.le16(off + 6))
                        merges.append((CellKey(row: r1 + 1, col: c1 + 1), CellKey(row: r2 + 1, col: c2 + 1)))
                        maxRow = max(maxRow, r2 + 1)
                        maxCol = max(maxCol, c2 + 1)
                    }
                }
            case 0x023E:   // WINDOW2（冻结窗格）
                if len >= 10 {
                    let flags = stream.le16(body)
                    if flags & 0x0008 != 0 { frozenRows = Int(stream.le16(body + 8)) }
                }
            default:
                _ = colFirst
            }
            p = body + len
        }

        // 有合并区时，右上角以外的格子要留空
        if debug {
            for (k, c) in cells.sorted(by: { $0.key.row == $1.key.row ? $0.key.col < $1.key.col : $0.key.row < $1.key.row }).prefix(4) {
                let xf = xfs[safe: c.style]
                let id = xf?.numFmtId ?? -1
                let code = formats[id] ?? NumFmt.builtin(id) ?? "nil"
                FileHandle.standardError.write("  格 \(k.row),\(k.col) xf=\(c.style) ifmt=\(id) code=\(code) text=\(c.text)\n".data(using: .utf8) ?? Data())
            }
        }
        var covered: Set<CellKey> = []
        var spanFor: [CellKey: (rs: Int, cs: Int)] = [:]
        for (a, b) in merges {
            let rs = b.row - a.row + 1, cs = b.col - a.col + 1
            guard rs > 0, cs > 0 else { continue }
            spanFor[a] = (rs, cs)
            for r in a.row...b.row {
                for c in a.col...b.col where !(r == a.row && c == a.col) {
                    covered.insert(CellKey(row: r, col: c))
                }
            }
        }
        for key in cells.keys {
            maxRow = max(maxRow, key.row)
            maxCol = max(maxCol, key.col)
        }

        let maxRows = 4000
        let shownRows = min(max(maxRow, 1), maxRows)
        let truncated = maxRow > maxRows
        let shownCols = min(max(maxCol, 1), 200)

        func colPx(_ c: Int) -> Double {
            let w = colWidths[c] ?? 8.43
            return max(28, w * 7.2 + 6)
        }

        var html = "<table class=\"sht\">"
        html += "<colgroup><col style=\"width:46px\"/>"
        for c in 1...shownCols { html += "<col style=\"width:\(fmt(colPx(c)))px\"/>" }
        html += "</colgroup><thead><tr class=\"hdr\"><th class=\"corner\"></th>"
        for c in 1...shownCols { html += "<th data-col=\"\(c)\">\(XlsxWorkbook.colName(c))</th>" }
        html += "</tr></thead><tbody>"

        for r in 1...shownRows {
            let h = rowHeights[r]
            html += "<tr data-row=\"\(r)\"\(h.map { " style=\"height:\(fmt($0))px\"" } ?? "")>"
            html += "<th class=\"rn\">\(r)</th>"
            var c = 1
            while c <= shownCols {
                let key = CellKey(row: r, col: c)
                if covered.contains(key) { c += 1; continue }
                let span = spanFor[key] ?? (1, 1)
                let cell = cells[key]
                let xf = cell.flatMap { xfs[safe: $0.style] }
                let css = cellCSS(xf)
                let colspan = span.cs > 1 ? " colspan=\"\(span.cs)\"" : ""
                let rowspan = span.rs > 1 ? " rowspan=\"\(min(span.rs, shownRows - r + 1))\"" : ""
                let text = cell?.text ?? ""
                let title = text.isEmpty ? "" : " title=\"\(XMLText.escape(text))\""
                let numCls = (cell?.numeric == true) ? " class=\"num\"" : ""
                let styleAttr = css.isEmpty ? "" : " style=\"\(css)\""
                html += "<td\(numCls)\(colspan)\(rowspan) data-c=\"\(c)\"\(styleAttr)\(title)>\(XMLText.escape(text))</td>"
                c += max(1, span.cs)
            }
            html += "</tr>"
        }
        html += "</tbody></table>"

        return XlsxWorkbook.Rendered(html: html, rowCount: maxRow, colCount: maxCol,
                                     truncated: truncated, frozenRows: frozenRows, frozenCols: 0)
    }

    private func put(_ cells: inout [CellKey: Cell], _ row: Int, _ col: Int, _ cell: Cell) {
        guard row >= 0, col >= 0, row < 65536, col < 1024 else { return }
        cells[CellKey(row: row + 1, col: col + 1)] = cell
    }

    private func cellCSS(_ xf: XF?) -> String {
        guard let xf else { return "" }
        var css = ""
        if xf.bold { css += "font-weight:700;" }
        if xf.italic { css += "font-style:italic;" }
        if xf.underline { css += "text-decoration:underline;" }
        if xf.strike { css += "text-decoration:line-through;" }
        if let s = xf.sizePt { css += "font-size:\(fmt(min(s, 42)))px;" }
        if let c = xf.color { css += "color:\(c);" }
        if let f = xf.fill { css += "background:\(f);" }
        if xf.wrap { css += "white-space:normal;word-break:break-word;" }
        if let h = xf.hAlign { css += "text-align:\(h);" }
        if let v = xf.vAlign { css += "vertical-align:\(v == "middle" ? "middle" : v);" }
        return css
    }

    // MARK: 值

    private func numberText(_ bits: UInt64, xf: Int) -> String {
        let v = Double(bitPattern: bits)
        return numberText(v, xf: xf)
    }

    private func numberText(_ v: Double, xf: Int) -> String {
        let style = xfs[safe: xf]
        let id = style?.numFmtId ?? 0
        let code = formats[id] ?? NumFmt.builtin(id)
        if NumFmt.isDate(id, code: code) {
            return NumFmt.date(v, code: code ?? "yyyy-mm-dd", date1904: date1904)
        }
        return NumFmt.number(v, code: code, styleId: id)
    }

    private func rkValue(_ raw: UInt32) -> Double {
        var d: Double
        if raw & 0x02 != 0 {
            // 30 位有符号整数
            let i = Int32(bitPattern: raw) >> 2
            d = Double(i)
        } else {
            let bits = UInt64(raw & 0xFFFF_FFFC) << 32
            d = Double(bitPattern: bits)
        }
        if raw & 0x01 != 0 { d /= 100 }
        return d
    }

    static func errorText(_ code: UInt8) -> String {
        switch code {
        case 0x00: return "#NULL!"
        case 0x07: return "#DIV/0!"
        case 0x0F: return "#VALUE!"
        case 0x17: return "#REF!"
        case 0x1D: return "#NAME?"
        case 0x24: return "#NUM!"
        case 0x2A: return "#N/A"
        default: return "#ERR"
        }
    }
}

extension XlsWorkbook: SheetSource {}

// MARK: - SST 跨 CONTINUE 的游标
/// SST 里一条字符串可能被切在两条记录之间；续接记录开头还有一个新的标志字节。
/// 这个游标负责在记录边界上"换行"，调用方只管按字符数取。
private final class SSTReader {
    private let chunks: [[UInt8]]
    private var ri = 0
    var pos = 0

    init(_ chunks: [[UInt8]]) { self.chunks = chunks }

    private var cur: [UInt8] { chunks[safe: ri] ?? [] }

    var atRecordEnd: Bool { pos >= cur.count }

    func nextRecord() -> Bool {
        guard ri + 1 < chunks.count else { return false }
        ri += 1
        pos = 0
        return true
    }

    func u8() -> UInt8? {
        while atRecordEnd {
            guard nextRecord() else { return nil }
        }
        defer { pos += 1 }
        return cur[pos]
    }

    func u16() -> UInt16? {
        guard let a = u8(), let b = u8() else { return nil }
        return UInt16(a) | (UInt16(b) << 8)
    }

    func u32() -> UInt32? {
        guard let a = u16(), let b = u16() else { return nil }
        return UInt32(a) | (UInt32(b) << 16)
    }

    func remainingUnits(wide: Bool) -> Int {
        let bytes = max(0, cur.count - pos)
        return wide ? bytes / 2 : bytes
    }

    func readUnits(_ n: Int, wide: Bool, into units: inout [UInt16]) {
        guard n > 0 else { return }
        if wide {
            for _ in 0..<n {
                guard pos + 2 <= cur.count else { break }
                units.append(UInt16(cur[pos]) | (UInt16(cur[pos + 1]) << 8))
                pos += 2
            }
        } else {
            for _ in 0..<n {
                guard pos < cur.count else { break }
                units.append(UInt16(cur[pos]))
                pos += 1
            }
        }
    }

    func skip(_ n: Int) {
        var left = n
        while left > 0 {
            if atRecordEnd {
                guard nextRecord() else { return }
            }
            let take = min(left, cur.count - pos)
            pos += take
            left -= take
        }
    }
}
