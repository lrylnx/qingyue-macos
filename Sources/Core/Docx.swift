import Foundation

/* docx → HTML。
 *
 * 覆盖面：段落/字符样式、标题大纲、粗斜体下划线删除线、字号颜色高亮、
 * 对齐缩进行距、项目符号与编号（含多级）、表格（含 gridSpan/vMerge）、
 * 内嵌图片（转 data URI，HTML 自包含）、超链接、分页符、域代码结果。
 * 不覆盖：批注、脚注正文、公式 OMML、艺术字、SmartArt —— 这些只留占位或者跳过。
 */

// MARK: - 数据模型

struct OutlineItem: Identifiable {
    let id = UUID()
    let level: Int
    let text: String
    let anchor: String
}

/// 可编辑段落：记录 w:p 的字节范围 + 其中每个 w:t 正文的范围
struct EditableParagraph {
    let index: Int
    let elementRange: Range<Int>
    let textRanges: [Range<Int>]
    let plainText: String
}

// MARK: - 解析器

final class DocxDocument {
    let archive: ZipArchive
    private(set) var html: String = ""
    private(set) var outline: [OutlineItem] = []
    private(set) var paragraphs: [EditableParagraph] = []
    private(set) var pageWidthPt: Double = 595      // A4
    private(set) var marginPt: Double = 56
    private(set) var docXML: [UInt8] = []

    // 样式
    private struct StyleInfo {
        var name: String = ""
        var outlineLevel: Int? = nil
        var bold = false, italic = false, strike = false, underline = false
        var sizePt: Double? = nil
        var color: String? = nil
        var basedOn: String? = nil
        var align: String? = nil
        var beforePt: Double? = nil, afterPt: Double? = nil
        var lineMultiple: Double? = nil
        var numId: String? = nil
        var indLeftPt: Double? = nil
    }
    private var styles: [String: StyleInfo] = [:]
    private var defaultStyle: StyleInfo = StyleInfo()
    private var rels: Relationships?
    private var numbering: [String: [(fmt: String, start: Int, text: String?)]] = [:]  // numId → levels

    private var counters: [String: [Int]] = [:]   // numId → 各级计数
    private var paraSeq = 0

    /// 正文默认字号（pt）。w:docDefaults 没写时按中文 Word 默认的 10.5pt（五号）
    var defaultBodySize: Double? {
        defaultStyle.sizePt ?? 10.5
    }

    init?(url: URL) {
        guard let z = ZipArchive(url: url) else { return nil }
        archive = z
        guard let docPath = z.exists("word/document.xml")
                ? "word/document.xml"
                : z.firstName(where: { $0.hasSuffix("document.xml") }) else { return nil }
        guard let bytes = z.rawData(docPath) else { return nil }
        docXML = bytes
        rels = Relationships.load(z, path: docPath)
        loadStyles()
        loadNumbering()
        render()
    }

    // MARK: 样式表

    private func loadStyles() {
        guard let xml = archive.string("word/styles.xml") else { return }
        let sc = XMLScanner(xml)
        var cur: StyleInfo? = nil
        var curId: String? = nil
        var inDefaults = false

        func flush() {
            if let id = curId, let s = cur { styles[id] = s }
            cur = nil; curId = nil
        }

        while let t = sc.next() {
            switch (t.kind, t.local) {
            case (.open, "docdefaults"):
                inDefaults = true
            case (.close, "docdefaults"):
                inDefaults = false
            case (.open, "style"):
                flush()
                if t.selfClosing { continue }
                curId = t.attr("styleId")
                cur = StyleInfo()
                if let b = t.attr("default"), b == "1" || b == "true" { inDefaults = true }
            case (.close, "style"):
                flush()
                inDefaults = false
            case (.open, "name"):
                let v = t.attr("val") ?? ""
                if cur != nil { cur!.name = v }
            case (.open, "basedon"):
                if cur != nil { cur!.basedOn = t.attr("val") }
            case (.open, "outlinelvl"):
                if let v = t.attr("val"), let n = Int(v), n < 9 {
                    if cur != nil { cur!.outlineLevel = n } else if inDefaults { defaultStyle.outlineLevel = n }
                }
            case (.open, "b"):
                let on = !(t.attr("val") == "0" || t.attr("val") == "false")
                if cur != nil { cur!.bold = on }
            case (.open, "i"):
                let on = !(t.attr("val") == "0" || t.attr("val") == "false")
                if cur != nil { cur!.italic = on }
            case (.open, "strike"):
                if cur != nil { cur!.strike = true }
            case (.open, "u"):
                if cur != nil, t.attr("val") != "none" { cur!.underline = true }
            case (.open, "sz"):
                if let v = t.attr("val"), let n = Double(v) {
                    if cur != nil { cur!.sizePt = n / 2 } else if inDefaults { defaultStyle.sizePt = n / 2 }
                }
            case (.open, "color"):
                if cur != nil, let v = t.attr("val"), v != "auto" { cur!.color = "#" + v }
            case (.open, "jc"):
                if cur != nil { cur!.align = t.attr("val") }
            case (.open, "spacing"):
                if cur != nil {
                    if let v = t.attr("before"), let n = Double(v) { cur!.beforePt = n / 20 }
                    if let v = t.attr("after"), let n = Double(v) { cur!.afterPt = n / 20 }
                    if let v = t.attr("line"), let n = Double(v), t.attr("lineRule") != "exact" {
                        cur!.lineMultiple = n / 240
                    }
                }
            case (.open, "numid"):
                if cur != nil { cur!.numId = t.attr("val") }
            case (.open, "ind"):
                if cur != nil, let v = t.attr("left") ?? t.attr("start"), let n = Double(v) {
                    cur!.indLeftPt = n / 20
                }
            default: break
            }
        }
        flush()
    }

    /// 沿 basedOn 链补全继承属性
    private func resolved(_ id: String?) -> StyleInfo {
        guard let id, var s = styles[id] else { return defaultStyle }
        var guardCount = 0
        var chain: [String] = [id]
        var cur = s.basedOn
        while let c = cur, let p = styles[c], guardCount < 8 {
            chain.append(c); s = merge(s, p); cur = p.basedOn; guardCount += 1
        }
        _ = chain
        return s
    }

    private func merge(_ child: StyleInfo, _ parent: StyleInfo) -> StyleInfo {
        var r = child
        if r.name.isEmpty { r.name = parent.name }
        if r.outlineLevel == nil { r.outlineLevel = parent.outlineLevel }
        if !r.bold { r.bold = parent.bold }
        if !r.italic { r.italic = parent.italic }
        if r.sizePt == nil { r.sizePt = parent.sizePt }
        if r.color == nil { r.color = parent.color }
        if r.align == nil { r.align = parent.align }
        if r.beforePt == nil { r.beforePt = parent.beforePt }
        if r.afterPt == nil { r.afterPt = parent.afterPt }
        if r.lineMultiple == nil { r.lineMultiple = parent.lineMultiple }
        if r.numId == nil { r.numId = parent.numId }
        if r.basedOn == nil { r.basedOn = parent.basedOn }
        return r
    }

    // MARK: 编号

    private func loadNumbering() {
        guard let xml = archive.string("word/numbering.xml") else { return }
        let sc = XMLScanner(xml)
        var abstracts: [String: [(String, Int, String?)]] = [:]
        var numToAbstract: [String: String] = [:]
        var curAbs: String? = nil
        var curNumId: String? = nil
        var levels: [(String, Int, String?)] = []
        var curLvl: Int? = nil
        var lvlFmt = "bullet"
        var lvlStart = 1
        var lvlText: String? = nil

        func commitLevel() {
            guard let lv = curLvl, curAbs != nil else { curLvl = nil; return }
            while levels.count <= lv { levels.append(("bullet", 1, nil)) }
            levels[lv] = (lvlFmt, lvlStart, lvlText)
            curLvl = nil; lvlFmt = "bullet"; lvlStart = 1; lvlText = nil
        }

        while let t = sc.next() {
            switch (t.kind, t.local) {
            case (.open, "abstractnum"):
                if let a = curAbs { abstracts[a] = levels }   // 收上一个
                curAbs = t.attr("abstractNumId")
                levels = []
            case (.close, "abstractnum"):
                commitLevel()
                if let a = curAbs { abstracts[a] = levels }
                curAbs = nil
            case (.open, "lvl"):
                commitLevel()
                curLvl = Int(t.attr("ilvl") ?? "0")
                if t.selfClosing { commitLevel() }
            case (.close, "lvl"):
                commitLevel()
            case (.open, "numfmt"):
                lvlFmt = t.attr("val") ?? "bullet"
            case (.open, "start") where curLvl != nil:
                lvlStart = Int(t.attr("val") ?? "1") ?? 1
            case (.open, "lvltext"):
                lvlText = t.attr("val")
            case (.open, "num"):
                curNumId = t.attr("numId")
            case (.close, "num"):
                curNumId = nil
            case (.open, "abstractnumid"):
                if let n = curNumId, let v = t.attr("val") { numToAbstract[n] = v }
            default: break
            }
        }
        for (n, a) in numToAbstract { if let l = abstracts[a] { numbering[n] = l } }
    }

    /// 返回 (标记文本, 层级)。标记由服务端算好，避免 CSS counter 在
    /// 「列表项之间夹了普通段落」时错位。
    private func bulletFor(numId: String, level: Int) -> (String, Int) {
        let lv = min(level, max(0, (numbering[numId]?.count ?? 1) - 1))
        let fmt = numbering[numId]?[safe: lv]?.0 ?? "bullet"
        var arr = counters[numId] ?? []
        while arr.count <= lv { arr.append(0) }
        if arr.count > lv {
            arr[lv] += 1
            for k in (lv + 1)..<arr.count { arr[k] = 0 }
        }
        counters[numId] = arr
        let n = arr[lv]
        switch fmt {
        case "bullet", "none":
            let marks = ["•", "◦", "▪"]
            return (marks[min(level, 2)], level)
        case "decimal", "decimalZero":
            return ("\(n).", level)
        case "lowerLetter":
            return ("\(letter(n)).", level)
        case "upperLetter":
            return ("\(letter(n).uppercased()).", level)
        case "lowerRoman":
            return (roman(n).lowercased() + ".", level)
        case "upperRoman":
            return (roman(n) + ".", level)
        case "chineseCounting", "chineseCountingThousand", "chineseLegalSimplified":
            return (cnNumber(n) + "、", level)
        case "ideographDigital":
            return (cnNumber(n), level)
        case "decimalEnclosedCircle", "decimalEnclosedCircleChinese":
            return (cnNumber(n) + "、", level)
        default:
            return ("\(n).", level)
        }
    }

    private func letter(_ n: Int) -> String {
        guard n > 0 else { return "a" }
        return String(UnicodeScalar(97 + (n - 1) % 26)!)
    }

    private func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
                                      (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
                                      (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = n, out = ""
        for (v, s) in table { while n >= v { out += s; n -= v } }
        return out
    }

    private func cnNumber(_ n: Int) -> String {
        let d = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        if n <= 10 { return d[max(0, n)] }
        if n < 20 { return "十" + d[n - 10] }
        if n < 100 {
            let t = n / 10, r = n % 10
            return d[t] + "十" + (r == 0 ? "" : d[r])
        }
        return "\(n)"
    }

    // MARK: 渲染

    private func render() {
        let sc = XMLScanner(docXML)
        var out = ""

        // 先读 sectPr 拿页面宽度（可能在 body 末尾，也可能在最后一个 pPr 里）
        pageWidthPt = 595; marginPt = 56
        if let sect = findSectPr() {
            if let w = sect["w"], let v = Double(w) { pageWidthPt = v / 20 }
            if let l = sect["l"], let r = sect["r"], let lv = Double(l), let rv = Double(r) {
                marginPt = (lv + rv) / 40
            }
        }

        guard findOpenTag(sc, "body") else { return }
        // w:sdt 直接穿过：sdt 里的 sdtContent 又包着普通 w:p，主循环天然会碰到，
        // 所以这一步不需要额外状态机。
        while let t = sc.next() {
            if t.kind == .close, t.local == "body" { break }
            guard t.kind == .open else { continue }
            switch t.local {
            case "p":
                out += renderParagraph(sc, t)
            case "tbl":
                out += renderTable(sc, t)
            default:
                break
            }
        }
        html = out
    }

    private func findOpenTag(_ sc: XMLScanner, _ local: String) -> Bool {
        while let t = sc.next() {
            if t.kind == .open, t.local == local { return true }
        }
        return false
    }

    private func findSectPr() -> [String: String]? {
        var result: [String: String]?
        let sc = XMLScanner(docXML)
        var captured: [String: String]? = nil
        while let t = sc.next() {
            if t.kind == .open, t.local == "sectpr" {
                captured = [:]
            } else if t.kind == .open, captured != nil {
                if t.local == "pgsz" {
                    captured?["w"] = t.attr("w"); captured?["h"] = t.attr("h")
                } else if t.local == "pgmar" {
                    captured?["l"] = t.attr("left"); captured?["r"] = t.attr("right")
                }
            } else if t.kind == .close, t.local == "sectpr" {
                if let c = captured { result = c }
                captured = nil
            }
        }
        return result
    }

    private func renderParagraph(_ sc: XMLScanner, _ pTok: XMLTok) -> String {
        let elStart = pTok.start

        // 段落属性
        var styleId: String? = nil
        var jc: String? = nil
        var numId: String? = nil
        var ilvl = 0
        var outlineLvl: Int? = nil
        var indLeft: Double? = nil
        var beforePt: Double? = nil, afterPt: Double? = nil, lineMul: Double? = nil
        var inPPr = false
        var runsHTML = ""
        var plain = ""
        var textRanges: [Range<Int>] = []
        var inDel = 0
        var containerStack: [String] = []
        var isPageBreak = false

        if pTok.selfClosing {
            let idx = paraSeq; paraSeq += 1
            paragraphs.append(EditableParagraph(index: idx, elementRange: elStart..<sc.i,
                                                textRanges: [], plainText: ""))
            return "<p class=\"pe\" data-p=\"\(idx)\"></p>"
        }

        loop: while let t = sc.next() {
            switch (t.kind, t.local) {
            case (.open, "ppr"):
                inPPr = true
            case (.close, "ppr"):
                inPPr = false
            case (.open, "pstyle") where inPPr:
                styleId = t.attr("val")
            case (.open, "jc") where inPPr:
                jc = t.attr("val")
            case (.open, "numid") where inPPr:
                let v = t.attr("val") ?? "0"
                if v != "0" { numId = v }
            case (.open, "ilvl") where inPPr:
                ilvl = Int(t.attr("val") ?? "0") ?? 0
            case (.open, "outlinelvl") where inPPr:
                if let v = t.attr("val"), let n = Int(v), n < 9 { outlineLvl = n }
            case (.open, "ind") where inPPr:
                if let v = t.attr("left") ?? t.attr("start"), let n = Double(v) { indLeft = n / 20 }
            case (.open, "spacing") where inPPr:
                if let v = t.attr("before"), let n = Double(v) { beforePt = n / 20 }
                if let v = t.attr("after"), let n = Double(v) { afterPt = n / 20 }
                if let v = t.attr("line"), let n = Double(v), t.attr("lineRule") != "exact" {
                    lineMul = n / 240
                }
            case (.open, "del"):
                inDel += 1
            case (.close, "del"):
                inDel = max(0, inDel - 1)
            case (.open, "p") where t.start != elStart:
                // 段落内的嵌套段落（罕见，多在文本框里）—— 跳过整段
                skipElement(sc, t)
            case (.open, "r"):
                if inDel == 0 { runsHTML += renderRun(sc, t, &plain, &textRanges, &isPageBreak) }
                else { skipElement(sc, t) }
            case (.open, "hyperlink"), (.open, "smarttag"), (.open, "fldsimple"),
                 (.open, "ins"), (.open, "sdt"), (.open, "sdtcontent"):
                if !t.selfClosing { containerStack.append(t.local) }
            case (.close, _):
                if let last = containerStack.last, last == t.local {
                    containerStack.removeLast()
                } else if t.local == "p" {
                    break loop
                }
            default:
                break
            }
        }

        let style = resolved(styleId)
        let effectiveOutline = outlineLvl ?? style.outlineLevel ?? (inferHeadingLevel(styleId, style))

        var cls = ["p"]
        var styleBits: [String] = []
        if let lv = effectiveOutline {
            cls.append("h\(min(lv + 1, 6))")
        }
        if let j = jc ?? style.align {
            switch j {
            case "center": styleBits.append("text-align:center")
            case "right", "end": styleBits.append("text-align:right")
            case "both", "distribute": styleBits.append("text-align:justify")
            default: break
            }
        }
        let indent = indLeft ?? style.indLeftPt
        if let i = indent, i > 0 { styleBits.append("margin-left:\(fmt(i))pt") }
        if let b = beforePt ?? style.beforePt, b > 0 { styleBits.append("margin-top:\(fmt(b))pt") }
        if let a = afterPt ?? style.afterPt, a > 0 { styleBits.append("margin-bottom:\(fmt(a))pt") }
        if let l = lineMul ?? style.lineMultiple, l > 1.02 { styleBits.append("line-height:\(fmt(l))") }

        var marker = ""
        if let nid = numId ?? style.numId {
            let (m, lv) = bulletFor(numId: nid, level: ilvl)
            marker = m
            cls.append("li")
            styleBits.append("--lv:\(lv)")
            if lv > 0 { styleBits.append("padding-left:\(fmt(Double(lv) * 1.6))em") }
        }

        // 编辑锚点必须每个段落都分配，空段落也算 —— 否则 HTML 里的 data-p
        // 与 paragraphs 下标会错开，点第 3 段改的却是第 5 段。
        let idx = paraSeq
        paraSeq += 1

        if plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !runsHTML.contains("<img") {
            paragraphs.append(EditableParagraph(index: idx, elementRange: elStart..<sc.i,
                                                textRanges: [], plainText: ""))
            if marker.isEmpty { return "<p class=\"pe\" data-p=\"\(idx)\"></p>" }
            return "<p class=\"p li\" data-p=\"\(idx)\" data-m=\"\(XMLText.escape(marker))\"><span class=\"bm\">\(XMLText.escape(marker))</span></p>"
        }

        var anchor = ""
        if let lv = effectiveOutline, !plain.trimmingCharacters(in: .whitespaces).isEmpty {
            let a = "h\(outline.count)"
            outline.append(OutlineItem(level: min(lv + 1, 6), text: plain.trimmingCharacters(in: .whitespaces), anchor: a))
            anchor = " id=\"\(a)\""
        }

        paragraphs.append(EditableParagraph(index: idx, elementRange: elStart..<sc.i,
                                            textRanges: textRanges, plainText: plain))

        let styleAttr = styleBits.isEmpty ? "" : " style=\"\(styleBits.joined(separator: ";"))\""
        let markerHTML = marker.isEmpty ? "" : "<span class=\"bm\">\(XMLText.escape(marker))</span>"
        let pageBreak = isPageBreak ? "<div class=\"pgbrk\"></div>" : ""
        return "<p class=\"\(cls.joined(separator: " "))\" data-p=\"\(idx)\"\(anchor)\(styleAttr)>\(markerHTML)\(runsHTML)</p>\(pageBreak)"
    }

    private func inferHeadingLevel(_ styleId: String?, _ s: StyleInfo) -> Int? {
        guard let id = styleId else { return nil }
        let lower = (id + " " + s.name).lowercased()
        for n in 1...6 {
            if lower.contains("heading \(n)") || lower.contains("标题 \(n)") || lower.contains("标题\(n)") {
                return n - 1
            }
        }
        if lower == "1" || lower.hasSuffix(":1") { return 0 }
        if lower == "2" { return 1 }
        if lower == "3" { return 2 }
        return nil
    }

    private func renderRun(_ sc: XMLScanner, _ rTok: XMLTok,
                           _ plain: inout String, _ ranges: inout [Range<Int>],
                           _ pageBreak: inout Bool) -> String {
        var b = false, i = false, u = false, strike = false
        var size: Double? = nil
        var color: String? = nil
        var highlight: String? = nil
        var vert: String? = nil
        var font: String? = nil
        var inRPr = false
        var html = ""
        var text = ""

        loop: while let t = sc.next() {
            switch (t.kind, t.local) {
            case (.open, "rpr"): inRPr = true
            case (.close, "rpr"): inRPr = false
            case (.open, "b") where inRPr:
                b = !(t.attr("val") == "0" || t.attr("val") == "false")
            case (.open, "i") where inRPr:
                i = !(t.attr("val") == "0" || t.attr("val") == "false")
            case (.open, "u") where inRPr:
                u = t.attr("val") != "none"
            case (.open, "strike") where inRPr:
                strike = true
            case (.open, "sz") where inRPr:
                if let v = t.attr("val"), let n = Double(v) { size = n / 2 }
            case (.open, "color") where inRPr:
                if let v = t.attr("val"), v != "auto" { color = "#" + v }
            case (.open, "highlight") where inRPr:
                highlight = t.attr("val")
            case (.open, "vertalign") where inRPr:
                vert = t.attr("val")
            case (.open, "rfonts") where inRPr:
                font = t.attr("eastAsia") ?? t.attr("ascii")
            case (.open, "t"):
                // 记录 w:t 正文的原始字节区间：编辑回写时就替换这一段，
                // 所以必须用「第一个 text token 的 start ~ 闭合标签的 start」，
                // 不能拿标签位置 +/- 固定偏移去推（标签可能带 xml:space 属性）。
                var content = ""
                var cStart = -1
                var cEnd = -1
                while let nt = sc.next() {
                    if nt.kind == .close, nt.local == "t" {
                        if cEnd < 0 { cEnd = nt.start }
                        break
                    }
                    if nt.kind == .text {
                        if cStart < 0 { cStart = nt.start }
                        content += nt.text
                        cEnd = nt.end
                    }
                }
                text += content
                if cStart >= 0, cEnd > cStart,
                   !content.trimmingCharacters(in: .whitespaces).isEmpty {
                    ranges.append(cStart..<cEnd)
                }
                html += XMLText.escape(content)
            case (.open, "deltext"):
                while let nt = sc.next() {
                    if nt.kind == .close, nt.local == "deltext" { break }
                }
            case (.open, "br"):
                if t.attr("type") == "page" { pageBreak = true }
                html += "<br/>"; text += "\n"
            case (.open, "tab"):
                html += "<span class=\"tab\"></span>"; text += "\t"
            case (.open, "cr"):
                html += "<br/>"; text += "\n"
            case (.open, "drawing"), (.open, "pict"), (.open, "object"):
                let (img, alt) = renderDrawing(sc, t)
                html += img; text += alt
            case (.close, "r"):
                break loop
            default:
                break
            }
        }

        plain += text
        var css: [String] = []
        if b { css.append("font-weight:700") }
        if i { css.append("font-style:italic") }
        var deco: [String] = []
        if u { deco.append("underline") }
        if strike { deco.append("line-through") }
        if !deco.isEmpty { css.append("text-decoration:\(deco.joined(separator: " "))") }
        if let s = size { css.append("font-size:\(fmt(s))pt") }
        if let c = color { css.append("color:\(c)") }
        if let h = highlight, let hc = highlightColor(h) { css.append("background:\(hc)") }
        if let v = vert {
            if v == "superscript" { css.append("vertical-align:super;font-size:.72em") }
            if v == "subscript" { css.append("vertical-align:sub;font-size:.72em") }
        }
        if let f = font, !f.isEmpty { css.append("font-family:'\(f.replacingOccurrences(of: "'", with: ""))'") }
        if css.isEmpty { return html }
        return "<span style=\"\(css.joined(separator: ";"))\">\(html)</span>"
    }

    private func highlightColor(_ v: String) -> String? {
        let m: [String: String] = ["yellow": "#FFF3A3", "green": "#B9F0B0", "cyan": "#AFF0F0",
                                   "magenta": "#F5B5F5", "blue": "#B3CCFF", "red": "#FFB3B3",
                                   "darkBlue": "#8FA6D9", "darkCyan": "#8FD9D9", "darkGreen": "#8FD98F",
                                   "darkMagenta": "#D98FD9", "darkRed": "#D98F8F", "darkYellow": "#D9C88F",
                                   "darkGray": "#BFBFBF", "lightGray": "#E6E6E6", "black": "#404040"]
        return m[v]
    }

    /// 图片：从 rels 找 media 文件，转 data URI
    private func renderDrawing(_ sc: XMLScanner, _ start: XMLTok) -> (String, String) {
        var embedId: String? = nil
        var hrefId: String? = nil
        var cx = 0.0, cy = 0.0
        var depth = 1
        var alt = ""

        while let t = sc.next() {
            if t.kind == .open {
                switch t.local {
                case "blip":
                    if let e = t.attr("embed") { embedId = e }
                    if let l = t.attr("link") { hrefId = l }
                case "extent":
                    if let x = t.attr("cx"), let n = Double(x) { cx = n }
                    if let y = t.attr("cy"), let n = Double(y) { cy = n }
                case "docpr":
                    if let d = t.attr("descr"), !d.isEmpty { alt = d }
                    else if let n = t.attr("name") { alt = n }
                case "imagedata":
                    if let e = t.attr("id") { embedId = e }
                default: break
                }
                if !t.selfClosing { depth += 1 }
            } else if t.kind == .close {
                depth -= 1
                if depth <= 0 { break }
            }
        }
        _ = hrefId

        guard let id = embedId, let path = rels?[id],
              let bytes = archive.rawData(path) else { return ("", "") }

        let mime: String
        switch (path as NSString).pathExtension.lowercased() {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "svg": mime = "image/svg+xml"
        case "bmp": mime = "image/bmp"
        case "tif", "tiff": mime = "image/tiff"
        case "webp": mime = "image/webp"
        case "emf", "wmf": return ("<span class=\"vecimg\">[\(mimeHint(path))]</span>",
                                   alt.isEmpty ? "" : "[图片]")
        default: mime = "image/png"
        }
        let b64 = Data(bytes).base64EncodedString()
        var style = "max-width:100%;height:auto"
        if cx > 0 { style += ";width:\(fmt(cx / 12700))pt;max-width:100%" }
        if cy > 0 && cx == 0 { style += ";height:\(fmt(cy / 12700))pt" }
        let altText = alt.isEmpty ? "" : " alt=\"\(XMLText.escape(alt))\""
        return ("<img class=\"pimg\" src=\"data:\(mime);base64,\(b64)\"\(altText) style=\"\(style)\"/>",
                alt.isEmpty ? "" : alt)
    }

    private func mimeHint(_ path: String) -> String {
        (path as NSString).pathExtension.uppercased()
    }

    // MARK: 表格

    private func renderTable(_ sc: XMLScanner, _ tblTok: XMLTok) -> String {
        var colWidths: [Double] = []
        var rowHTML: [String] = []
        var tblW: Double? = nil
        var inGrid = false

        while let t = sc.next() {
            switch (t.kind, t.local) {
            case (.open, "tblgrid"):
                inGrid = true
            case (.close, "tblgrid"):
                inGrid = false
            case (.open, "gridcol") where inGrid:
                colWidths.append(Double(t.attr("w") ?? "0") ?? 0)
            case (.open, "tblw"):
                if let v = t.attr("w"), let n = Double(v) { tblW = n / 20 }
            case (.open, "tr"):
                rowHTML.append(renderRow(sc, t))
            case (.close, "tbl"):
                return assembleTable(colWidths, rowHTML, tblW)
            default:
                break
            }
        }
        return assembleTable(colWidths, rowHTML, tblW)
    }

    /// 渲染一行。注意：绝不能在这里吞掉 </w:tbl>（上面那个循环要靠它收尾），
    /// 正常文档里 </w:tr> 一定先出现，所以只认 </w:tr>。
    private func renderRow(_ sc: XMLScanner, _ trTok: XMLTok) -> String {
        var cells = ""
        var col = 0

        while let t = sc.next() {
            switch (t.kind, t.local) {
            case (.open, "tc"):
                let r = renderCell(sc, t)
                if r.cont {
                    cells += "<td class=\"vc\"></td>"
                } else {
                    var style = ""
                    if let s = r.shade { style += "background:\(s);" }
                    let attr = style.isEmpty ? "" : " style=\"\(style)\""
                    let colspan = r.span > 1 ? " colspan=\"\(r.span)\"" : ""
                    let cls = r.start ? " class=\"vms\"" : ""
                    cells += "<td\(cls)\(colspan)\(attr)>\(r.html)</td>"
                }
                col += r.span
            case (.close, "tr"):
                return "<tr>\(cells)</tr>"
            default: break
            }
        }
        _ = col
        return "<tr>\(cells)</tr>"
    }

    private struct CellResult {
        var html = ""
        var span = 1
        var start = false     // vMerge restart
        var cont = false      // vMerge continue（这一格直接空着，靠 rowspan 撑）
        var shade: String? = nil
    }

    private func renderCell(_ sc: XMLScanner, _ tcTok: XMLTok) -> CellResult {
        var r = CellResult()
        var inTcPr = false

        if tcTok.selfClosing { return r }

        while let t = sc.next() {
            switch (t.kind, t.local) {
            case (.open, "tcpr"): inTcPr = true
            case (.close, "tcpr"): inTcPr = false
            case (.open, "gridspan") where inTcPr:
                r.span = Int(t.attr("val") ?? "1") ?? 1
            case (.open, "vmerge") where inTcPr:
                if t.attr("val") == "restart" { r.start = true } else { r.cont = true }
            case (.open, "shd") where inTcPr:
                if let f = t.attr("fill"), f != "auto" { r.shade = "#" + f }
            case (.open, "p"):
                r.html += renderCellParagraph(sc, t)
            case (.open, "tbl"):
                r.html += renderTable(sc, t)
            case (.close, "tc"):
                return r
            default: break
            }
        }
        return r
    }

    /// 表格单元格里的段落：不产生编辑锚点，只保留格式。
    /// 只认 </w:p> 作为终点 —— 若误吞 </w:tc>，外层 renderCell 就再也收不到它，
    /// 整个表格会一路吃到文档末尾。
    private func renderCellParagraph(_ sc: XMLScanner, _ pTok: XMLTok) -> String {
        if pTok.selfClosing { return "" }
        var html = ""
        var jc: String? = nil
        var inPPr = false
        var b = false, i = false, u = false
        var size: Double? = nil
        var color: String? = nil

        while let t = sc.next() {
            if t.kind == .close, t.local == "p" { break }
            switch (t.kind, t.local) {
            case (.open, "ppr"): inPPr = true
            case (.close, "ppr"): inPPr = false
            case (.open, "jc") where inPPr: jc = t.attr("val")
            case (.open, "b"): b = true
            case (.open, "i"): i = true
            case (.open, "u"):
                if t.attr("val") != "none" { u = true }
            case (.open, "sz"):
                if let v = t.attr("val"), let n = Double(v) { size = n / 2 }
            case (.open, "color"):
                if let v = t.attr("val"), v != "auto" { color = "#" + v }
            case (.open, "t"):
                var s = ""
                while let nt = sc.next() {
                    if nt.kind == .close, nt.local == "t" { break }
                    if nt.kind == .text { s += nt.text }
                }
                html += XMLText.escape(s)
            case (.open, "br"):
                html += "<br/>"
            case (.open, "tab"):
                html += "<span class=\"tab\"></span>"
            case (.open, "drawing"), (.open, "pict"):
                let (img, _) = renderDrawing(sc, t)
                html += img
            default: break
            }
        }
        return wrapCellPara(html, jc, b, i, u, size, color)
    }

    private func wrapCellPara(_ html: String, _ jc: String?, _ b: Bool, _ i: Bool,
                              _ u: Bool, _ size: Double?, _ color: String?) -> String {
        var css: [String] = []
        if let j = jc {
            switch j {
            case "center": css.append("text-align:center")
            case "right": css.append("text-align:right")
            default: break
            }
        }
        if b { css.append("font-weight:700") }
        if i { css.append("font-style:italic") }
        if u { css.append("text-decoration:underline") }
        if let s = size { css.append("font-size:\(fmt(s))pt") }
        if let c = color { css.append("color:\(c)") }
        let st = css.isEmpty ? "" : " style=\"\(css.joined(separator: ";"))\""
        return "<p class=\"cp\"\(st)>\(html)</p>"
    }

    private func assembleTable(_ widths: [Double], _ rows: [String], _ tblW: Double?) -> String {
        var body = rows.joined()
        var colsHTML = ""
        let total = widths.reduce(0, +)
        let widthAttr: String
        if let w = tblW, w > 0 {
            widthAttr = " style=\"width:\(fmt(min(w, pageWidthPt)))pt\""
        } else {
            widthAttr = " style=\"width:100%\""
        }
        if total > 0 {
            for w in widths where w > 0 {
                colsHTML += "<col style=\"width:\(fmt(w / total * 100))%\"/>"
            }
        }
        if body.isEmpty { body = "<tr><td></td></tr>" }
        return "<table class=\"tb\"\(widthAttr)>\(colsHTML.isEmpty ? "" : "<colgroup>\(colsHTML)</colgroup>")<tbody>\(body)</tbody></table>"
    }

    private func skipElement(_ sc: XMLScanner, _ t: XMLTok) {
        if t.selfClosing { return }
        var depth = 1
        while depth > 0, let nt = sc.next() {
            if nt.kind == .open, !nt.selfClosing, nt.name == t.name { depth += 1 }
            else if nt.kind == .close, nt.name == t.name { depth -= 1 }
        }
    }

    // MARK: 编辑

    /// 把第 index 段落的文字替换成 newText，返回重新打包后的 docx。
    ///
    /// 策略：新文字塞进第一个 w:t，其余 w:t 清空。这样段落里原有的加粗/颜色等
    /// run 格式不会丢，但「一段里几种格式混排」会被压成第一种 —— 这是刻意的取舍，
    /// 真要做富文本编辑就该上 NSTextView + 完整 OOXML 模型了，不是这个 App 的定位。
    func applyText(_ newText: String, toParagraph index: Int) -> Data? {
        guard index >= 0, index < paragraphs.count else { return nil }
        let p = paragraphs[index]
        guard p.textRanges.first != nil else { return nil }

        var bytes = docXML
        let escaped = Array(XMLText.escape(newText).utf8)   // 必须在写回前转义
        // 从后往前替换，避免前面的替换让后面的偏移失效
        for (k, r) in p.textRanges.enumerated().reversed() {
            guard r.lowerBound <= r.upperBound, r.upperBound <= bytes.count else { continue }
            bytes.replaceSubrange(r, with: k == 0 ? escaped : [])
        }

        var items: [ZipWriter.Item] = []
        for e in archive.entries {
            if e.name == "word/document.xml" {
                items.append(.init(name: e.name, bytes: bytes))
            } else if let d = archive.rawData(e.name) {
                items.append(.init(name: e.name, bytes: d))
            }
        }
        return ZipWriter.build(items)
    }
}

// MARK: - 小工具

func fmt(_ v: Double) -> String {
    if v == v.rounded() { return String(Int(v.rounded())) }
    return String(format: "%.1f", v)
}

extension Array {
    subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
