import Foundation

/* pptx → HTML。
 *
 * 核心思路：把每张幻灯片当成一块固定逻辑尺寸（1280 × 宽高比）的画布，
 * 每个形状按 xfrm 换算成百分比绝对定位，字号按 pt→px 比例换算。
 * 外层用 CSS transform 自适应窗口宽度，所以放大缩小只影响 scale，
 * 不影响内部布局 —— 这样文字位置永远和 PowerPoint 里一致。
 *
 * 覆盖：矩形/圆角/椭圆/线条、纯色填充、边框、文本框（对齐/行距/段距/
 * 垂直居中）、图片、组合（含子坐标系换算）、表格、主题色与主题字体。
 * 不覆盖：动画、切换、SmartArt、图表（只画占位框）、艺术字效果。
 */

/// 组合坐标变换：canvas = off + (local - chOff) * scale
struct GroupXf {
    var offX = 0.0, offY = 0.0
    var chX = 0.0, chY = 0.0
    var sx = 1.0, sy = 1.0

    func map(_ x: Double, _ y: Double) -> (Double, Double) {
        (offX + (x - chX) * sx, offY + (y - chY) * sy)
    }
    var isIdentity: Bool { offX == 0 && offY == 0 && chX == 0 && chY == 0 && sx == 1 && sy == 1 }
}

final class PptxDocument {
    let archive: ZipArchive
    private(set) var slidePaths: [String] = []
    private(set) var slideTitles: [String] = []
    private(set) var slideWidthPt: Double = 960
    private(set) var slideHeightPt: Double = 540

    private var themeColors: [String: String] = [:]
    private var minorFont: String = "PingFang SC"
    private var rels: Relationships?

    private let logicalWidth = 1280.0
    private var logicalHeight: Double { logicalWidth * slideHeightPt / slideWidthPt }
    private var pxPerPt: Double { logicalWidth / slideWidthPt }

    init?(url: URL) {
        guard let z = ZipArchive(url: url) else { return nil }
        archive = z
        rels = Relationships.load(z, path: "ppt/presentation.xml")
        loadPresentation()
        guard !slidePaths.isEmpty else { return nil }
        loadTheme()
    }

    private func loadPresentation() {
        guard let xml = archive.string("ppt/presentation.xml") else { return }
        let sc = XMLScanner(xml)
        while let t = sc.next() {
            switch (t.kind, t.local) {
            case (.open, "sldsz"):
                if let cx = t.attr("cx"), let cy = t.attr("cy"),
                   let x = Double(cx), let y = Double(cy), x > 0 {
                    slideWidthPt = x / 12700
                    slideHeightPt = y / 12700
                }
            case (.open, "sldid"):
                if let rid = t.attr("id"), let p = rels?[rid] { slidePaths.append(p) }
            default: break
            }
        }
        if slidePaths.isEmpty {
            var found: [(Int, String)] = []
            for e in archive.entries where e.name.hasPrefix("ppt/slides/slide") && e.name.hasSuffix(".xml") {
                let n = Int(e.name.replacingOccurrences(of: "ppt/slides/slide", with: "")
                    .replacingOccurrences(of: ".xml", with: "")) ?? 0
                found.append((n, e.name))
            }
            slidePaths = found.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    private func loadTheme() {
        guard let path = archive.firstName(where: { $0.hasPrefix("ppt/theme/theme") && $0.hasSuffix(".xml") }),
              let xml = archive.string(path) else { return }
        let sc = XMLScanner(xml)
        var inClrScheme = false
        var curSlot: String? = nil
        let slots = ["dk1", "lt1", "dk2", "lt2", "accent1", "accent2", "accent3",
                     "accent4", "accent5", "accent6", "hlink", "folhlink"]

        while let t = sc.next() {
            switch (t.kind, t.local) {
            case (.open, "clrscheme"): inClrScheme = true
            case (.close, "clrscheme"): inClrScheme = false
            case (.open, "latin"):
                // fontScheme 里的 latin typeface（majorFont/minorFont 都会命中，
                // 用最后一处即可，差异极小）
                if let tf = t.attr("typeface"), !tf.isEmpty, !tf.hasPrefix("+") { minorFont = tf }
            case (.open, _) where inClrScheme && slots.contains(t.local):
                curSlot = t.local
            case (.open, "srgbclr") where curSlot != nil:
                if let v = t.attr("val") { themeColors[curSlot!] = v }
                curSlot = nil
            case (.open, "sysclr") where curSlot != nil:
                if let v = t.attr("lastClr") { themeColors[curSlot!] = v }
                curSlot = nil
            default: break
            }
        }
    }

    // MARK: 渲染

    func renderAll() -> String {
        var out = ""
        var titles: [String] = []
        for (i, path) in slidePaths.enumerated() {
            guard let xml = archive.string(path) else { continue }
            let srels = Relationships.load(archive, path: path)
            let (html, title) = renderSlide(xml: xml, rels: srels, index: i)
            titles.append(title)
            out += html
        }
        slideTitles = titles
        return out
    }

    private func renderSlide(xml: String, rels: Relationships?, index: Int) -> (String, String) {
        let sc = XMLScanner(xml)
        var body = ""
        var title = ""
        var bg = ""

        while let t = sc.next() {
            guard t.kind == .open else { continue }
            switch t.local {
            case "bg":
                bg = parseBackground(sc, t)
            case "sp", "pic", "graphicframe", "grpsp", "cxnsp":
                let (h, txt) = renderShape(sc, t, rels: rels, g: GroupXf())
                body += h
                if title.isEmpty, txt.count > 1 { title = txt }
            default:
                break
            }
        }

        let section = "<section class=\"slide\" id=\"s\(index + 1)\" style=\"width:\(fmt(logicalWidth))px;height:\(fmt(logicalHeight))px;\(bg)\">\(body)</section>"
        return (section, title.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func parseBackground(_ sc: XMLScanner, _ bgTok: XMLTok) -> String {
        var color: String? = nil
        var depth = 1
        while depth > 0, let t = sc.next() {
            if t.kind == .open {
                if t.local == "srgbclr", let v = t.attr("val"), color == nil { color = "#" + v }
                if t.local == "schemeclr", let v = t.attr("val"), color == nil { color = schemeColor(v) }
                if !t.selfClosing { depth += 1 }
            } else if t.kind == .close {
                depth -= 1
            }
        }
        return color.map { "background:\($0)" } ?? "background:#FFFFFF"
    }

    private func schemeColor(_ name: String) -> String {
        let map: [String: String] = ["bg1": "lt1", "tx1": "dk1", "bg2": "lt2", "tx2": "dk2"]
        let key = map[name] ?? name
        if let v = themeColors[key] { return "#" + v }
        switch key {
        case "accent1": return "#4472C4"
        case "accent2": return "#ED7D31"
        case "accent3": return "#A5A5A5"
        case "accent4": return "#FFC000"
        case "accent5": return "#5B9BD5"
        case "accent6": return "#70AD47"
        default: return "#000000"
        }
    }

    // MARK: 形状

    private func renderShape(_ sc: XMLScanner, _ tok: XMLTok, rels: Relationships?,
                             g: GroupXf) -> (String, String) {
        if tok.selfClosing { return ("", "") }
        let kind = tok.local

        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        var hasXfrm = false
        var prst = "rect"
        var fill: String? = nil
        var lineColor: String? = nil
        var lineWidthPt = 0.0
        var rot = 0.0
        var flipH = false, flipV = false
        var anchor = "t"
        var wrapMode: String? = nil
        var insetL = 7.2, insetR = 7.2, insetT = 3.6, insetB = 3.6
        var imageId: String? = nil
        var tableHTML: String? = nil
        var textHTML = ""
        var textPlain = ""
        var styleFillIdx: Int? = nil
        var styleLnIdx: Int? = nil
        var fillLevel = 0
        var inLn = false
        var inRPrCtx = false
        var childGroup = g
        var childHTML = ""
        var hasChildren = false
        var hasCustomGeom = false

        // 渐变：PPT 的装饰元素基本都是「浅色 + 低透明度」的渐变，
        // 只取第一个色会画出实心色块（封面上那块突兀的黄方块就是这么来的）
        struct GradStop { var pos: Double; var color: String; var alpha: Double }
        var gradStops: [GradStop] = []
        var gradIsRadial = false
        var gradAngleDeg = 0.0
        var fillAlpha = 1.0
        var lineAlpha = 1.0

        // 组自身的子坐标系
        var chX = 0.0, chY = 0.0, chW = 0.0, chH = 0.0

        func finishShape() -> (String, String) {
            // 组合自身不画东西，只输出子内容
            if kind == "grpsp" {
                return (childHTML, textPlain)
            }
            let (cx, cy) = g.map(x, y)
            let cw = w * g.sx, chh = h * g.sy

            // 没有 xfrm 的形状（多见于继承母版位置的占位符）：
            // 不绝对定位，改成流式块，至少让文字看得见，而不是整块消失
            if !hasXfrm {
                if imageId != nil || tableHTML != nil || !textPlain.isEmpty {
                    return ("<div class=\"sh-flow\">\(tableHTML ?? "")\(textPlain.isEmpty ? "" : "<p>\(XMLText.escape(textPlain))</p>")</div>", textPlain)
                }
                return ("", "")
            }

            var css = "left:\(fmt(cx / logicalWidth * 100))%;"
            css += "top:\(fmt(cy / logicalHeight * 100))%;"
            css += "width:\(fmt(max(cw, 0.5) / logicalWidth * 100))%;"
            css += "height:\(fmt(max(chh, 0.5) / logicalHeight * 100))%;"

            var bgCSS = ""
            if kind == "cxnsp" {
                if let lc = lineColor { bgCSS = "background:\(lc);" }
            } else if gradStops.count >= 2 {
                let stops = gradStops
                    .sorted { $0.pos < $1.pos }
                    .map { "\(Self.rgba($0.color, $0.alpha)) \(fmt($0.pos))%" }
                    .joined(separator: ",")
                if gradIsRadial {
                    bgCSS = "background:radial-gradient(circle at 50% 50%,\(stops));"
                } else {
                    let deg = (gradAngleDeg + 90).truncatingRemainder(dividingBy: 360)
                    bgCSS = "background:linear-gradient(\(fmt(deg))deg,\(stops));"
                }
            } else if gradStops.count == 1 {
                bgCSS = "background:\(Self.rgba(gradStops[0].color, gradStops[0].alpha));"
            } else if let f = fill {
                bgCSS = "background:\(Self.rgba(f, fillAlpha));"
            } else if let idx = styleFillIdx, idx > 0 {
                bgCSS = "background:\(schemeColor("accent\(min(idx, 6))"));"
            }

            var borderCSS = ""
            if let lc = lineColor, lineWidthPt > 0 {
                borderCSS = "border:\(fmt(pxPerPt * lineWidthPt))px solid \(Self.rgba(lc, lineAlpha));"
            } else if let idx = styleLnIdx, idx > 0, kind != "cxnsp" {
                borderCSS = "border:1px solid \(schemeColor("accent\(min(idx, 6))"));"
            }

            var radius = ""
            switch prst {
            case "ellipse", "circle":
                radius = "border-radius:50%;"
            case "roundRect", "round2SameRect", "round1Rect", "round2DiagRect":
                radius = "border-radius:12px;"
            default:
                // 自定义路径（custGeom）读不出具体形状，正方形就按圆处理：
                // PPT 里多数手绘/装饰图元就是圆或圆角，当方块画会非常突兀
                if hasCustomGeom, w > 1, h > 1, abs(w - h) < max(w, h) * 0.14 {
                    radius = "border-radius:50%;"
                }
            }

            var transform = ""
            if rot != 0 { transform += "transform:rotate(\(fmt(rot))deg);" }
            if flipH || flipV {
                transform += "transform:scaleX(\(flipH ? -1 : 1)) scaleY(\(flipV ? -1 : 1));"
            }

            var inner = ""
            if let img = imageId, let path = rels?[img], let bytes = archive.rawData(path) {
                let b64 = Data(bytes).base64EncodedString()
                inner = "<img src=\"data:\(mimeType(path));base64,\(b64)\" style=\"width:100%;height:100%;object-fit:contain\"/>"
            } else if let tbl = tableHTML {
                inner = tbl
            } else if !textHTML.isEmpty {
                let justify: String
                switch anchor {
                case "ctr": justify = "center"
                case "b": justify = "flex-end"
                default: justify = "flex-start"
                }
                // wrap="none" 的文本框在 PPT 里本来就不换行，字大了就往右溢出。
                // 按固定宽度排版会把「概论」这种大字拆成两行，完全变样。
                let nowrap = (wrapMode == "none")
                inner = "<div class=\"tx\(nowrap ? " nowrap" : "")\" style=\"justify-content:\(justify);padding:\(fmt(insetT))px \(fmt(insetR))px \(fmt(insetB))px \(fmt(insetL))px\">\(textHTML)</div>"
            }

            let cls = kind == "pic" ? "sh pic" : "sh"
            let out = "<div class=\"\(cls)\" style=\"\(css)\(bgCSS)\(borderCSS)\(radius)\(transform)\">\(inner)</div>"
            return (out, textPlain)
        }

        while let t = sc.next() {
            if t.kind == .open {
                switch t.local {
                case "xfrm":
                    var depth = t.selfClosing ? 0 : 1
                    while depth > 0, let nt = sc.next() {
                        if nt.kind == .open {
                            switch nt.local {
                            case "off":
                                if let a = nt.attr("x"), let b = nt.attr("y"),
                                   let dx = Double(a), let dy = Double(b) {
                                    x = dx / 12700 * pxPerPt
                                    y = dy / 12700 * pxPerPt
                                }
                            case "ext":
                                if let a = nt.attr("cx"), let b = nt.attr("cy"),
                                   let dx = Double(a), let dy = Double(b) {
                                    w = dx / 12700 * pxPerPt
                                    h = dy / 12700 * pxPerPt
                                    hasXfrm = true
                                }
                            case "choff":
                                if let a = nt.attr("x"), let b = nt.attr("y"),
                                   let dx = Double(a), let dy = Double(b) {
                                    chX = dx / 12700 * pxPerPt
                                    chY = dy / 12700 * pxPerPt
                                }
                            case "chext":
                                if let a = nt.attr("cx"), let b = nt.attr("cy"),
                                   let dx = Double(a), let dy = Double(b) {
                                    chW = dx / 12700 * pxPerPt
                                    chH = dy / 12700 * pxPerPt
                                }
                            default: break
                            }
                            if !nt.selfClosing { depth += 1 }
                        } else if nt.kind == .close { depth -= 1 }
                    }
                    // 组合：把子坐标系算成变换
                    if kind == "grpsp", chW > 0, chH > 0, w > 0, h > 0 {
                        childGroup = GroupXf(offX: x, offY: y, chX: chX, chY: chY,
                                             sx: w / chW, sy: h / chH)
                    }
                case "prstgeom":
                    if let p = t.attr("prst") { prst = p }
                case "solidfill":
                    fillLevel += 1
                    if t.selfClosing { fillLevel = max(0, fillLevel - 1) }
                case "gradfill":
                    fillLevel += 1
                    gradStops = []
                case "gs":
                    if fillLevel > 0 {
                        let pos = (Double(t.attr("pos") ?? "0") ?? 0) / 1000
                        gradStops.append(GradStop(pos: pos, color: "#000000", alpha: 1))
                    }
                case "lin":
                    // 注意 a:lin（渐变方向）和 a:ln（边框）只差一个字母
                    if let v = t.attr("ang"), let n = Double(v) { gradAngleDeg = n / 60000 }
                case "path":
                    if fillLevel > 0, t.attr("path") == "circle" { gradIsRadial = true }
                case "custgeom":
                    hasCustomGeom = true
                case "ln":
                    if t.selfClosing { break }          // <a:ln/> 空边框，别留下 inLn 残状态
                    inLn = true
                    if let v = t.attr("w"), let n = Double(v) { lineWidthPt = n / 12700 }
                case "alpha":
                    if let v = t.attr("val"), let n = Double(v) {
                        if inLn { lineAlpha = n / 100000 }
                        else if fillLevel > 0 {
                            if !gradStops.isEmpty { gradStops[gradStops.count - 1].alpha = n / 100000 }
                            else { fillAlpha = n / 100000 }
                        }
                    }
                case "srgbclr":
                    if let v = t.attr("val") {
                        let c = "#" + v
                        if inLn { lineColor = c }
                        else if fillLevel > 0 {
                            if gradStops.isEmpty { if fill == nil { fill = c } }
                            else { gradStops[gradStops.count - 1].color = c }
                        }
                    }
                case "schemeclr":
                    if let v = t.attr("val") {
                        let c = schemeColor(v)
                        if inLn { lineColor = c }
                        else if fillLevel > 0 {
                            if gradStops.isEmpty { if fill == nil { fill = c } }
                            else { gradStops[gradStops.count - 1].color = c }
                        }
                    }
                case "fillref":
                    if let v = t.attr("idx"), let n = Int(v) { styleFillIdx = n }
                case "lnref":
                    if let v = t.attr("idx"), let n = Int(v) { styleLnIdx = n }
                case "bodypr":
                    anchor = t.attr("anchor") ?? "t"
                    wrapMode = t.attr("wrap")
                    if let v = t.attr("lIns"), let n = Double(v) { insetL = n / 12700 * pxPerPt }
                    if let v = t.attr("rIns"), let n = Double(v) { insetR = n / 12700 * pxPerPt }
                    if let v = t.attr("tIns"), let n = Double(v) { insetT = n / 12700 * pxPerPt }
                    if let v = t.attr("bIns"), let n = Double(v) { insetB = n / 12700 * pxPerPt }
                case "blip":
                    if let e = t.attr("embed") { imageId = e }
                case "txbody":
                    var insets = [insetL, insetR, insetT, insetB]
                    let (th, tp) = renderTextBody(sc, anchor: &anchor,
                                                  wrap: &wrapMode, insets: &insets)
                    insetL = insets[0]; insetR = insets[1]
                    insetT = insets[2]; insetB = insets[3]
                    textHTML += th
                    textPlain += tp
                case "tbl":
                    tableHTML = renderTable(sc, t)
                case "sp", "pic", "grpsp", "cxnsp", "graphicframe":
                    // 组合内的子形状
                    if kind == "grpsp" {
                        let (ch, ct) = renderShape(sc, t, rels: rels, g: childGroup)
                        childHTML += ch
                        if textPlain.isEmpty { textPlain = ct }
                        hasChildren = true
                    } else {
                        skipElement(sc, t)
                    }
                case "rpr":
                    inRPrCtx = true
                default: break
                }
                if t.selfClosing, t.local == "rpr" { inRPrCtx = false }
            } else if t.kind == .close {
                switch t.local {
                case "solidfill", "gradfill":
                    fillLevel = max(0, fillLevel - 1)
                case "ln":
                    inLn = false
                case "rpr":
                    inRPrCtx = false
                case "sp", "pic", "cxnsp", "graphicframe", "grpsp":
                    return finishShape()
                default: break
                }
            } else if t.kind == .text {
                // 形状直接文本（不该出现，兜底）
                break
            }
        }
        return finishShape()

    }

    private func skipElement(_ sc: XMLScanner, _ t: XMLTok) {
        if t.selfClosing { return }
        var depth = 1
        while depth > 0, let nt = sc.next() {
            if nt.kind == .open, !nt.selfClosing, nt.name == t.name { depth += 1 }
            else if nt.kind == .close, nt.name == t.name { depth -= 1 }
        }
    }

    private func mimeType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    /// "#RRGGBB" + alpha → rgba()；不透明时原样返回，少一层解析开销
    static func rgba(_ hex: String, _ alpha: Double) -> String {
        let a = max(0, min(1, alpha))
        guard a < 0.999 else { return hex }
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count >= 6, let v = UInt32(h.prefix(6), radix: 16) else { return hex }
        let r = (v >> 16) & 0xFF
        let g = (v >> 8) & 0xFF
        let b = v & 0xFF
        return "rgba(\(r),\(g),\(b),\(String(format: "%.3f", a)))"
    }

    // MARK: 文本

    /// 解析 <p:txBody>。
    /// 注意 a:bodyPr 在 txBody 内部、a:p 之前，所以必须在这里顺手读掉 ——
    /// 放在外层 switch 里永远看不到它（这个函数已经把整个 txBody 吃完了）。
    private func renderTextBody(_ sc: XMLScanner,
                                anchor: inout String,
                                wrap: inout String?,
                                insets: inout [Double]) -> (String, String) {
        var html = ""
        var plain = ""
        while let t = sc.next() {
            if t.kind == .close, t.local == "txbody" { break }
            if t.kind == .open {
                switch t.local {
                case "bodypr":
                    if let a = t.attr("anchor") { anchor = a }
                    if let w = t.attr("wrap") { wrap = w }
                    if let v = t.attr("lIns"), let n = Double(v) { insets[0] = n / 12700 * pxPerPt }
                    if let v = t.attr("rIns"), let n = Double(v) { insets[1] = n / 12700 * pxPerPt }
                    if let v = t.attr("tIns"), let n = Double(v) { insets[2] = n / 12700 * pxPerPt }
                    if let v = t.attr("bIns"), let n = Double(v) { insets[3] = n / 12700 * pxPerPt }
                case "p":
                    let (ph, pt) = renderParagraph(sc, t)
                    html += ph
                    if !pt.isEmpty { plain += pt + " " }
                default: break
                }
            }
        }
        return (html, plain)
    }

    private struct RunStyle {
        var size: Double? = nil
        var bold = false, italic = false, underline = false, strike = false
        var color: String? = nil
        var font: String? = nil
        var baseline: Int = 0
    }

    private func renderParagraph(_ sc: XMLScanner, _ pTok: XMLTok) -> (String, String) {
        var align = "l"
        var marL = 0.0
        var indent = 0.0
        var linePct: Double? = nil
        var spaceBefore: Double? = nil
        var spaceAfter: Double? = nil
        var bullet: String? = nil
        var html = ""
        var plain = ""
        var inPPr = false

        if pTok.selfClosing { return ("", "") }

        while let t = sc.next() {
            if t.kind == .close, t.local == "p" { break }
            if t.kind == .open {
                switch t.local {
                case "ppr":
                    inPPr = true
                    // DrawingML 把段落格式写在 a:pPr 的**属性**上，
                    // 不是 <a:algn val=""/> 这种子元素（那是 Word 的写法）。
                    if let v = t.attr("algn") { align = v }
                    if let v = t.attr("marL"), let n = Double(v) { marL = n / 12700 * pxPerPt }
                    if let v = t.attr("indent"), let n = Double(v) { indent = n / 12700 * pxPerPt }
                case "algn" where inPPr: align = t.attr("val") ?? align
                case "marl" where inPPr:
                    if let v = t.attr("val"), let n = Double(v) { marL = n / 12700 * pxPerPt }
                case "indent" where inPPr:
                    if let v = t.attr("val"), let n = Double(v) { indent = n / 12700 * pxPerPt }
                case "lnspc":
                    if let v = t.attr("val"), let n = Double(v) { linePct = n / 100000 }
                case "spcbfr":
                    if let v = t.attr("val"), let n = Double(v) { spaceBefore = n / 100 }
                case "spcaft":
                    if let v = t.attr("val"), let n = Double(v) { spaceAfter = n / 100 }
                case "buchar":
                    bullet = t.attr("char")
                case "bunone":
                    bullet = nil
                case "r":
                    let (rh, rt) = renderRun(sc, t)
                    html += rh
                    plain += rt
                case "br":
                    html += "<br/>"
                default: break
                }
                if t.selfClosing, t.local == "ppr" { inPPr = false }
            } else if t.kind == .close, t.local == "ppr" {
                inPPr = false
            }
        }

        var css: [String] = []
        switch align {
        case "ctr": css.append("text-align:center")
        case "r": css.append("text-align:right")
        case "just": css.append("text-align:justify")
        default: break
        }
        if marL > 0 { css.append("margin-left:\(fmt(marL))px") }
        if indent != 0 { css.append("text-indent:\(fmt(indent))px") }
        if let l = linePct { css.append("line-height:\(fmt(l))") }
        if let b = spaceBefore, b > 0 { css.append("margin-top:\(fmt(b * pxPerPt))px") }
        if let a = spaceAfter, a > 0 { css.append("margin-bottom:\(fmt(a * pxPerPt))px") }

        var prefix = ""
        if let b = bullet, let scalar = b.unicodeScalars.first, b != "\u{0}" {
            prefix = "<span class=\"bu\">\(XMLText.escape(String(scalar)))</span>"
        }

        let styleAttr = css.isEmpty ? "" : " style=\"\(css.joined(separator: ";"))\""
        return ("<p\(styleAttr)>\(prefix)\(html)</p>", plain)
    }

    private func renderRun(_ sc: XMLScanner, _ rTok: XMLTok) -> (String, String) {
        var st = RunStyle()
        var html = ""
        var plain = ""
        var inRPr = false
        var inFill = false
        var inShadow = false
        var shadowColor: String? = nil
        var shadowAlpha = 1.0
        var shadowCSS: String? = nil
        var shDX = 0.0, shDY = 0.0, shBlur = 0.0

        if rTok.selfClosing { return ("", "") }

        while let t = sc.next() {
            if t.kind == .close, t.local == "r" { break }
            if t.kind == .open {
                switch t.local {
                case "rpr":
                    inRPr = true
                    // 关键：<a:rPr sz="2400" b="1" i="0" u="sng" strike="noStrike"
                    //        baseline="30000"/> 全部是**属性**。按 <a:sz val=""/> 去读
                    // 会一直读到 nil，表现出来就是所有字号都变成默认值、粗体全丢。
                    if let v = t.attr("sz"), let n = Double(v) { st.size = n / 100 }
                    if let v = t.attr("b") { st.bold = (v == "1" || v == "true") }
                    if let v = t.attr("i") { st.italic = (v == "1" || v == "true") }
                    if let v = t.attr("u") { st.underline = (v != "none") }
                    if let v = t.attr("strike") { st.strike = (v != "noStrike") }
                    if let v = t.attr("baseline"), let n = Int(v) { st.baseline = n }
                case "t":
                    var s = ""
                    while let nt = sc.next() {
                        if nt.kind == .close, nt.local == "t" { break }
                        if nt.kind == .text { s += nt.text }
                    }
                    plain += s
                    html += XMLText.escape(s)
                case "solidfill":
                    inFill = true
                case "outershdw":
                    inShadow = true
                    let blur = (Double(t.attr("blurRad") ?? "0") ?? 0) / 12700 * pxPerPt
                    let dist = (Double(t.attr("dist") ?? "0") ?? 0) / 12700 * pxPerPt
                    let dir = (Double(t.attr("dir") ?? "0") ?? 0) / 60000 * Double.pi / 180
                    shBlur = blur
                    // DrawingML 方向：0°=向右，90°=向下
                    shDX = dist * cos(dir)
                    shDY = dist * sin(dir)
                    if t.selfClosing { inShadow = false }
                case "srgbclr":
                    if let v = t.attr("val") {
                        if inShadow { shadowColor = "#" + v }
                        else if inRPr, inFill { st.color = "#" + v }
                    }
                case "schemeclr":
                    if let v = t.attr("val") {
                        if inShadow { shadowColor = schemeColor(v) }
                        else if inRPr, inFill { st.color = schemeColor(v) }
                    }
                case "alpha":
                    if inShadow, let v = t.attr("val"), let n = Double(v) { shadowAlpha = n / 100000 }
                case "latin", "ea":
                    if inRPr, let f = t.attr("typeface"), !f.hasPrefix("+") { st.font = f }
                default: break
                }
                // 注意：本地标签名一律小写，这里比较必须用小写 "rpr"
                if t.selfClosing {
                    if t.local == "rpr" { inRPr = false }
                    if t.local == "solidfill" { inFill = false }
                }
            } else if t.kind == .close {
                if t.local == "rpr" { inRPr = false }
                if t.local == "solidfill" { inFill = false }
                if t.local == "outershdw" {
                    inShadow = false
                    if let c = shadowColor {
                        shadowCSS = "text-shadow:\(fmt(shDX))px \(fmt(shDY))px \(fmt(shBlur))px \(Self.rgba(c, shadowAlpha))"
                    }
                }
            }
        }

        var css: [String] = []
        if let s = st.size { css.append("font-size:\(fmt(s * pxPerPt))px") }
        if st.bold { css.append("font-weight:700") }
        if st.italic { css.append("font-style:italic") }
        if st.underline { css.append("text-decoration:underline") }
        if st.strike { css.append("text-decoration:line-through") }
        if let c = st.color { css.append("color:\(c)") }
        if let f = st.font {
            css.append("font-family:'\(f)',\(minorFont)")
        }
        if st.baseline > 0 { css.append("vertical-align:super;font-size:.7em") }
        if st.baseline < 0 { css.append("vertical-align:sub;font-size:.7em") }
        if let sh = shadowCSS { css.append(sh) }

        if css.isEmpty { return (html, plain) }
        return ("<span style=\"\(css.joined(separator: ";"))\">\(html)</span>", plain)
    }

    // MARK: 表格

    private func renderTable(_ sc: XMLScanner, _ tblTok: XMLTok) -> String {
        var rows = ""
        var curRow = ""
        var cellHTML = ""
        var colWidths: [Double] = []
        var span = 1
        var rowSpan = 1
        var inTcPr = false
        var cellFill: String? = nil

        while let t = sc.next() {
            if t.kind == .open {
                switch t.local {
                case "gridcol":
                    if let w = t.attr("w"), let n = Double(w) { colWidths.append(n) }
                case "tr": curRow = ""
                case "tc":
                    cellHTML = ""; span = 1; rowSpan = 1; cellFill = nil
                case "tcpr": inTcPr = true
                case "gridspan":
                    if let v = t.attr("val"), let n = Int(v) { span = n }
                case "rowspan":
                    if let v = t.attr("val"), let n = Int(v) { rowSpan = n }
                case "srgbclr":
                    if inTcPr, let v = t.attr("val"), cellFill == nil { cellFill = "#" + v }
                case "schemeclr":
                    if inTcPr, let v = t.attr("val"), cellFill == nil { cellFill = schemeColor(v) }
                case "txbody":
                    var a = "t", w: String? = nil
                    var ins = [7.2, 7.2, 3.6, 3.6]
                    let (h, _) = renderTextBody(sc, anchor: &a, wrap: &w, insets: &ins)
                    cellHTML += h
                default: break
                }
                if t.selfClosing, t.local == "tcpr" { inTcPr = false }
            } else if t.kind == .close {
                switch t.local {
                case "tcpr": inTcPr = false
                case "tc":
                    let cAttr = span > 1 ? " colspan=\"\(span)\"" : ""
                    let rAttr = rowSpan > 1 ? " rowspan=\"\(rowSpan)\"" : ""
                    let st = cellFill.map { " style=\"background:\($0)\"" } ?? ""
                    curRow += "<td\(cAttr)\(rAttr)\(st)>\(cellHTML)</td>"
                case "tr":
                    rows += "<tr>\(curRow)</tr>"
                case "tbl":
                    var cols = ""
                    let total = colWidths.reduce(0, +)
                    if total > 0 {
                        for w in colWidths { cols += "<col style=\"width:\(fmt(w / total * 100))%\"/>" }
                    }
                    return "<table class=\"pt\">\(cols.isEmpty ? "" : "<colgroup>\(cols)</colgroup>")<tbody>\(rows)</tbody></table>"
                default: break
                }
            }
        }
        return "<table class=\"pt\"><tbody>\(rows)</tbody></table>"
    }
}
