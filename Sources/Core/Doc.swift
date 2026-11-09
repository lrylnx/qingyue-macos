import Foundation

/* .doc / .wps（Word 97-2003 与 WPS 文字）读取。
 *
 * 文本不在一个连续区里：FIB 指向 CLX，CLX 里的「片段表」把字符位置切成若干段，
 * 每段给出它在 WordDocument 流里的真实偏移，还可能压缩成单字节（英文文档常见）。
 * 字符属性和段落属性放在另一套「FKP」分页表里，按 FC 区间查 —— 所以解码每个字符时
 * 必须同时记住它原来的 FC，否则粗体/字号/对齐全都对不上。
 *
 * 只读，且不做表格排版、不做图文混排。
 */

final class LegacyDoc {
    private(set) var html: String = ""
    private(set) var outline: [OutlineItem] = []
    private(set) var pageWidthPt: Double = 595
    private(set) var marginPt: Double = 56
    private(set) var defaultBodySize: Double? = nil

    private let word: [UInt8]
    private let table: [UInt8]
    private var pieces: [(cpStart: Int, cpEnd: Int, fc: Int, compressed: Bool)] = []
    private var charRuns: [CharRun] = []
    private var paraRuns: [ParaRun] = []

    struct CharProps: Equatable {
        var bold = false
        var italic = false
        var strike = false
        var underline = false
        var sizeHalfPt: Int? = nil
        var color: String? = nil
        var highlight: String? = nil
    }

    struct ParaProps: Equatable {
        var align: String? = nil
        var indentLeft: Int = 0     // twips
        var indentFirst: Int = 0    // twips
        var spaceBefore: Int = 0
        var spaceAfter: Int = 0
        var inTable = false
    }

    struct CharRun { var fcStart: Int; var fcEnd: Int; var props: CharProps }
    struct ParaRun { var fcStart: Int; var fcEnd: Int; var props: ParaProps }

    convenience init?(url: URL) {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        self.init(data: [UInt8](raw))
    }

    init?(data: [UInt8]) {
        guard let cfb = CFB(data), let w = cfb.firstStream(among: ["WordDocument"]) else { return nil }
        guard w.le16(0) == 0xA5EC else { return nil }
        word = w
        let which = (w.le16(10) & 0x0200) != 0 ? "1Table" : "0Table"
        table = cfb.firstStream(among: [which, "0Table", "1Table"]) ?? []

        guard readPieceTable() else { return nil }
        readCharProps()
        readParaProps()
        if ProcessInfo.processInfo.environment["QY_DEBUG"] != nil {
            let msg = "DocDebug: nFib=\(w.le16(2)) fcClx=\(w.le32(418)) lcb=\(w.le32(422)) pieces=\(pieces.count) "
                + "fcChpx=\(w.le32(250)) lcbChpx=\(w.le32(254)) charRuns=\(charRuns.count) "
                + "fcPapx=\(w.le32(258)) lcbPapx=\(w.le32(262)) paraRuns=\(paraRuns.count)\n"
            FileHandle.standardError.write(msg.data(using: .utf8) ?? Data())
            for pc in pieces.prefix(6) {
                FileHandle.standardError.write("  piece cp=\(pc.cpStart)..\(pc.cpEnd) fc=\(pc.fc) compressed=\(pc.compressed)\n".data(using: .utf8) ?? Data())
            }
            for r in charRuns.prefix(6) {
                FileHandle.standardError.write("  run fc=\(r.fcStart)..\(r.fcEnd) bold=\(r.props.bold) size=\(r.props.sizeHalfPt.map(String.init) ?? "-") color=\(r.props.color ?? "-")\n".data(using: .utf8) ?? Data())
            }
        }
        buildHTML()
    }

    // MARK: - 片段表

    private func readPieceTable() -> Bool {
        let fcClx = Int(word.le32(418))
        let lcbClx = Int(word.le32(422))
        guard fcClx > 0, lcbClx > 0, fcClx + lcbClx <= table.count else { return false }

        var p = fcClx
        let end = fcClx + lcbClx
        // 跳过 Prc（0x01）段，找到 Pcdt（0x02）
        while p < end {
            let clxt = table[p]
            if clxt == 0x01 {
                let cb = Int(table.le16(p + 1))
                p += 3 + cb
            } else if clxt == 0x02 {
                let lcb = Int(table.le32(p + 1))
                let plc = p + 5
                guard plc + lcb <= table.count else { return false }
                let n = (lcb - 4) / 12
                guard n > 0 else { return false }
                for i in 0..<n {
                    let cpStart = Int(table.le32(plc + i * 4))
                    let cpEnd = Int(table.le32(plc + (i + 1) * 4))
                    let pcdOff = plc + (n + 1) * 4 + i * 8
                    guard pcdOff + 8 <= table.count else { break }
                    let fcRaw = table.le32(pcdOff + 2)
                    let compressed = (fcRaw & 0x4000_0000) != 0
                    // 压缩片段里 fc 是「真实偏移的一半」
                    let fc = compressed ? Int(fcRaw & 0x3FFF_FFFF) / 2 : Int(fcRaw & 0x3FFF_FFFF)
                    pieces.append((cpStart, cpEnd, fc, compressed))
                }
                return !pieces.isEmpty
            } else {
                break
            }
        }
        return false
    }

    // MARK: - 属性表

    private func readCharProps() {
        let fcPlc = Int(word.le32(250))
        let lcbPlc = Int(word.le32(254))
        guard fcPlc > 0, lcbPlc >= 4, fcPlc + lcbPlc <= table.count else { return }
        let n = (lcbPlc - 4) / 8
        guard n > 0 else { return }
        for i in 0..<n {
            let pn = Int(table.le32(fcPlc + (n + 1) * 4 + i * 4) & 0x003F_FFFF)
            let base = pn * 512
            guard base + 512 <= word.count else { continue }
            let crun = Int(word[base + 511])
            guard crun > 0, 4 * (crun + 1) + crun <= 511 else { continue }
            for j in 0..<crun {
                let fcStart = Int(word.le32(base + j * 4))
                let fcEnd = Int(word.le32(base + (j + 1) * 4))
                let off = Int(word[base + 4 * (crun + 1) + j])
                var props = CharProps()
                if off > 0 {
                    let at = base + off * 2
                    guard at < base + 511 else { continue }
                    let cb = Int(word[at])
                    if cb > 0, at + 1 + cb <= word.count {
                        if ProcessInfo.processInfo.environment["QY_SPRM"] != nil, charRuns.count < 8 {
                            let hex = word.slice(at + 1, cb).map { String(format: "%02x", $0) }.joined(separator: " ")
                            FileHandle.standardError.write("CHPX fc=\(fcStart)..\(fcEnd) cb=\(cb) sprm=\(hex)\n".data(using: .utf8) ?? Data())
                        }
                        applyCharSPRMs(word.slice(at + 1, cb), into: &props)
                    }
                }
                charRuns.append(CharRun(fcStart: fcStart, fcEnd: fcEnd, props: props))
            }
        }
        charRuns.sort { $0.fcStart < $1.fcStart }
    }

    private func readParaProps() {
        let fcPlc = Int(word.le32(258))
        let lcbPlc = Int(word.le32(262))
        guard fcPlc > 0, lcbPlc >= 4, fcPlc + lcbPlc <= table.count else { return }
        let n = (lcbPlc - 4) / 8
        guard n > 0 else { return }
        for i in 0..<n {
            let pn = Int(table.le32(fcPlc + (n + 1) * 4 + i * 4) & 0x003F_FFFF)
            let base = pn * 512
            guard base + 512 <= word.count else { continue }
            let crun = Int(word[base + 511])
            guard crun > 0 else { continue }
            let rgbx = 4 * (crun + 1)
            guard rgbx + crun * 13 <= 512 else { continue }
            for j in 0..<crun {
                let fcStart = Int(word.le32(base + j * 4))
                let fcEnd = Int(word.le32(base + (j + 1) * 4))
                let bOffset = Int(word[base + rgbx + j * 13])
                var props = ParaProps()
                if bOffset > 0 {
                    var at = base + bOffset * 2
                    guard at + 1 < base + 512 else { continue }
                    var cb = Int(word[at])
                    at += 1
                    if cb == 0 {
                        guard at < base + 512 else { continue }
                        cb = Int(word[at]) * 2
                        at += 1
                    }
                    // 前 2 字节是 istd（段落样式编号），跳过
                    if cb > 2, at + 2 + cb - 2 <= word.count {
                        applyParaSPRMs(word.slice(at + 2, cb - 2), into: &props)
                    }
                }
                paraRuns.append(ParaRun(fcStart: fcStart, fcEnd: fcEnd, props: props))
            }
        }
        paraRuns.sort { $0.fcStart < $1.fcStart }
    }

    // MARK: - SPRM

    /// sprm 的操作数长度由最高 3 位（spra）决定：0/1=1字节 2/4/5=2字节 3=4字节 6=变长 7=3字节
    private func operandSize(_ sprm: UInt16, _ b: [UInt8], _ i: inout Int) -> Int {
        switch Int(sprm >> 13) {
        case 0, 1: return 1
        case 2, 4, 5: return 2
        case 3: return 4
        case 7: return 3
        default:
            // 变长：只有表格定义那几个用 2 字节长度，其余是 1 字节
            if sprm == 0xD608 || sprm == 0xD606 {
                guard i + 2 <= b.count else { return 0 }
                let n = Int(b.le16(i))
                i += 2
                return n
            }
            guard i + 1 <= b.count else { return 0 }
            let n = Int(b[i])
            i += 1
            return n
        }
    }

    private func applyCharSPRMs(_ b: [UInt8], into p: inout CharProps) {
        var i = 0
        while i + 2 <= b.count {
            let sprm = b.le16(i)
            i += 2
            let size = operandSize(sprm, b, &i)
            let take = Swift.min(size, b.count - i)
            guard take > 0 else { break }
            let v = b.slice(i, take)
            switch sprm {
            case 0x0835: p.bold = flag(v)
            case 0x0836: p.italic = flag(v)
            case 0x0837: p.strike = flag(v)
            case 0x2A3E: p.underline = v.count >= 1 && v[0] != 0
            case 0x4A43: if v.count >= 2 { p.sizeHalfPt = Int(v.le16(0)) }
            case 0x2A42: if let c = v.first { p.color = Self.colorName(c) }
            case 0x2A0C: if let c = v.first { p.highlight = Self.highlight(c) }
            default: break
            }
            i += take
        }
    }

    private func applyParaSPRMs(_ b: [UInt8], into p: inout ParaProps) {
        var i = 0
        while i + 2 <= b.count {
            let sprm = b.le16(i)
            i += 2
            let size = operandSize(sprm, b, &i)
            let take = Swift.min(size, b.count - i)
            guard take > 0 else { break }
            let v = b.slice(i, take)
            switch sprm {
            case 0x2403:   // 对齐
                if let j = v.first {
                    p.align = [0: "left", 1: "center", 2: "right", 3: "justify"][Int(j)]
                }
            case 0x840F:   // 左缩进（twips）
                if v.count >= 2 { p.indentLeft = Int(Int16(bitPattern: v.le16(0))) }
            case 0x8411:   // 首行缩进（twips，可为负）
                if v.count >= 2 { p.indentFirst = Int(Int16(bitPattern: v.le16(0))) }
            case 0xA413:   // 段前距
                if v.count >= 2 { p.spaceBefore = Int(v.le16(0)) }
            case 0xA414:   // 段后距
                if v.count >= 2 { p.spaceAfter = Int(v.le16(0)) }
            default:
                break
            }
            i += take
        }
    }

    private func flag(_ v: [UInt8]) -> Bool {
        guard let b = v.first else { return false }
        // 0=关 1=开 128=切换 129=不变
        return b == 1 || b == 128
    }

    // MARK: - 组装

    private func buildHTML() {
        var chars: [UInt16] = []
        var styles: [Int] = []          // 每个字符的 CharProps 索引
        var styleKeys: [CharProps] = []

        func styleIndex(_ p: CharProps) -> Int {
            if let i = styleKeys.firstIndex(of: p) { return i }
            styleKeys.append(p)
            return styleKeys.count - 1
        }

        for piece in pieces {
            let count = piece.cpEnd - piece.cpStart
            guard count > 0 else { continue }
            if piece.compressed {
                guard piece.fc + count <= word.count else { continue }
                for k in 0..<count {
                    let byte = word[piece.fc + k]
                    // 压缩片段里一个字符占 **一个** FC（不是两个），属性表也是这么记的
                    let fc = piece.fc + k
                    chars.append(Self.cp1252(byte))
                    styles.append(styleIndex(charProps(at: fc)))
                }
            } else {
                let need = count * 2
                guard piece.fc + need <= word.count else { continue }
                for k in 0..<count {
                    let fc = piece.fc + k * 2
                    chars.append(word.le16(fc))
                    styles.append(styleIndex(charProps(at: fc)))
                }
            }
        }

        // 按段落切：0x0D 是段尾，0x07 是单元格/行尾，0x0B 是软回车，0x0C 是分页
        var html = ""
        var para: [(UInt16, Int)] = []
        var idx = 0
        var pageBreakPending = false

        func flushPara(_ endFC: Int) {
            let props = paraProps(at: endFC)
            html += renderParagraph(para, styleKeys: styleKeys, props: props, pageBreak: pageBreakPending)
            pageBreakPending = false
            para.removeAll(keepingCapacity: true)
        }

        // 计算每段的 FC：段尾字符的 FC 决定段落属性
        var fcs = [Int](repeating: 0, count: chars.count)
        var cursor = 0
        for piece in pieces {
            let count = piece.cpEnd - piece.cpStart
            for k in 0..<count where cursor + k < fcs.count {
                fcs[cursor + k] = piece.compressed ? piece.fc + k : piece.fc + k * 2
            }
            cursor += count
        }

        var fieldState = 0   // 0 正常，1 在域指令里（隐藏），2 在域结果里（显示）
        while idx < chars.count {
            let ch = chars[idx]
            let fc = fcs[idx]
            switch ch {
            case 0x13: fieldState = 1; idx += 1; continue
            case 0x14: fieldState = 2; idx += 1; continue
            case 0x15: fieldState = 0; idx += 1; continue
            case 0x0D, 0x07:
                flushPara(fc)
                idx += 1
                continue
            case 0x0B:
                para.append((0x2028, styles[idx]))   // 软回车 → 行分隔符
                idx += 1
                continue
            case 0x0C:
                pageBreakPending = true
                idx += 1
                continue
            case 0x01, 0x08:
                idx += 1
                continue
            default:
                break
            }
            if fieldState == 1 { idx += 1; continue }   // 域指令不显示
            if ch == 0x1E { para.append((0x2D, styles[idx])) ; idx += 1; continue }  // 不间断连字符
            if ch == 0x1F { idx += 1; continue }          // 可选连字符
            if ch == 0x09 { para.append((0x09, styles[idx])); idx += 1; continue }
            if ch < 0x20 && ch != 0x0A { idx += 1; continue }
            para.append((ch, styles[idx]))
            idx += 1
        }
        if !para.isEmpty { flushPara(fcs.last ?? 0) }

        // 正文默认字号取出现最多的那一号
        var tally: [Int: Int] = [:]
        for s in styleKeys {
            if let h = s.sizeHalfPt, h > 0 { tally[h, default: 0] += 1 }
        }
        if let best = tally.max(by: { $0.value < $1.value })?.key {
            defaultBodySize = Double(best) / 2.0
        }

        self.html = html
    }

    private func charProps(at fc: Int) -> CharProps {
        if let r = charRuns.last(where: { $0.fcStart <= fc }), fc < r.fcEnd { return r.props }
        return CharProps()
    }

    private func paraProps(at fc: Int) -> ParaProps {
        if let r = paraRuns.last(where: { $0.fcStart <= fc }), fc < r.fcEnd { return r.props }
        if let r = paraRuns.last(where: { $0.fcStart <= fc }) { return r.props }
        return ParaProps()
    }

    private func renderParagraph(_ para: [(UInt16, Int)], styleKeys: [CharProps],
                                 props: ParaProps, pageBreak: Bool) -> String {
        if para.isEmpty {
            return "<p class=\"p\" style=\"margin:0;height:0.9em\"></p>"
        }
        var css = "margin:0 0 0 0;"
        if props.spaceBefore > 0 { css += "margin-top:\(fmt(Double(props.spaceBefore) / 15.0))px;" }
        if props.spaceAfter > 0 { css += "margin-bottom:\(fmt(Double(props.spaceAfter) / 15.0))px;" }
        if props.indentLeft != 0 { css += "padding-left:\(fmt(Double(props.indentLeft) / 15.0))px;" }
        if props.indentFirst != 0 { css += "text-indent:\(fmt(Double(props.indentFirst) / 15.0))px;" }
        if let a = props.align { css += "text-align:\(a);" }

        var body = ""
        var runText = ""
        var runStyle: CharProps? = nil

        func flushRun() {
            guard !runText.isEmpty else { return }
            body += spanFor(runText, runStyle)
            runText = ""
        }

        for (ch, si) in para {
            let s = styleKeys[safe: si] ?? CharProps()
            if runStyle == nil { runStyle = s }
            if s != runStyle! {
                flushRun()
                runStyle = s
            }
            runText.unicodeScalars.append(UnicodeScalar(ch) ?? " ")
        }
        flushRun()

        let brk = pageBreak ? "<div class=\"pgbrk\"></div>" : ""
        return brk + "<p class=\"p\" data-p=\"0\" style=\"\(css)\">\(body.isEmpty ? "<br/>" : body)</p>"
    }

    private func spanFor(_ text: String, _ s: CharProps?) -> String {
        guard let s else { return XMLText.escape(text) }
        var css = ""
        if s.bold { css += "font-weight:700;" }
        if s.italic { css += "font-style:italic;" }
        if s.strike { css += "text-decoration:line-through;" }
        if s.underline { css += "text-decoration:underline;" }
        if let h = s.sizeHalfPt, h > 0 { css += "font-size:\(fmt(Double(h) / 2.0))pt;" }
        if let c = s.color { css += "color:\(c);" }
        if let hl = s.highlight { css += "background:\(hl);" }
        let escaped = XMLText.escape(text).replacingOccurrences(of: "\t", with: "&nbsp;&nbsp;&nbsp;&nbsp;")
        if css.isEmpty { return escaped }
        return "<span style=\"\(css)\">\(escaped)</span>"
    }

    private static func cp1252(_ b: UInt8) -> UInt16 {
        // 0x80–0x9F 在 CP1252 里是特殊标点（0x92 = ’），其余直接就是 Latin-1 码位。
        // Word 的「压缩片段」就是单字节文本，CJK 内容不会压缩（会用双字节），所以这里够用。
        let table: [UInt16] = [
            0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
            0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
            0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
            0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
        ]
        if b >= 0x80 && b <= 0x9F { return table[Int(b - 0x80)] }
        return UInt16(b)
    }

    private static func colorName(_ ico: UInt8) -> String? {
        switch ico {
        case 0: return nil            // 自动
        case 1: return "#000000"
        case 2: return "#0000FF"
        case 3: return "#00FFFF"
        case 4: return "#00FF00"
        case 5: return "#FF00FF"
        case 6: return "#FF0000"
        case 7: return "#FFFF00"
        case 8: return "#FFFFFF"
        case 9: return "#000080"
        case 10: return "#008080"
        case 11: return "#008000"
        case 12: return "#800080"
        case 13: return "#800000"
        case 14: return "#808000"
        case 15: return "#808080"
        case 16: return "#C0C0C0"
        default: return nil
        }
    }

    private static func highlight(_ code: UInt8) -> String? {
        switch code {
        case 1: return "#000000"
        case 2: return "#0000FF"
        case 3: return "#00FFFF"
        case 4: return "#00FF00"
        case 5: return "#FF00FF"
        case 6: return "#FF0000"
        case 7: return "#FFFF00"
        case 8: return "#FFFFFF"
        case 9: return "#000080"
        case 10: return "#008080"
        case 11: return "#008000"
        case 12: return "#800080"
        case 13: return "#800000"
        case 14: return "#808000"
        case 15: return "#808080"
        case 16: return "#C0C0C0"
        default: return nil
        }
    }
}
