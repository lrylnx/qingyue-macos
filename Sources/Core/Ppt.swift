import Foundation

/* .ppt / .dps（PowerPoint 97-2003 与 WPS 演示）读取。
 *
 * 和 doc/xls 不一样，ppt 没有「一条流就是全部内容」的结构，而是层层嵌套的记录树：
 * 每条记录 8 字节头（4 位版本 + 12 位实例号 + 2 字节类型 + 4 字节长度），子记录直接接在
 * 父记录的负载里。幻灯片的文字集中在 SlideListWithText 容器：每个 SlidePersistAtom
 * 开启一页，后面跟着若干 TextCharsAtom（UTF-16 文本，段落用 \r 分隔）。
 *
 * 只做文本视图：不动画、不排版、不解析自选图形路径。
 */

final class LegacyPpt {
    private(set) var slideTexts: [[String]] = []
    private(set) var slideTitles: [String] = []
    private(set) var slideWidthPt: Double = 720
    private(set) var slideHeightPt: Double = 540

    private let stream: [UInt8]

    convenience init?(url: URL) {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        self.init(data: [UInt8](raw))
    }

    init?(data: [UInt8]) {
        guard let cfb = CFB(data) else { return nil }
        if ProcessInfo.processInfo.environment["QY_DEBUG"] != nil {
            FileHandle.standardError.write("PptDebug: 流 \(cfb.streamNames)\n".data(using: .utf8) ?? Data())
        }
        guard let s = cfb.firstStream(among: ["PowerPoint Document"]) else { return nil }
        stream = s
        guard stream.count > 8 else { return nil }
        parse()
        if ProcessInfo.processInfo.environment["QY_DEBUG"] != nil {
            FileHandle.standardError.write("PptDebug: 顶层 type=\(record(at: 0)?.type ?? 0) 页数=\(slideTexts.count)\n".data(using: .utf8) ?? Data())
        }
        guard !slideTexts.isEmpty else { return nil }
    }

    // MARK: - 记录遍历

    private struct Rec {
        let type: UInt16
        let inst: UInt16
        let start: Int      // 负载起点
        let end: Int        // 负载终点
    }

    private func record(at p: Int) -> Rec? {
        guard p + 8 <= stream.count else { return nil }
        let verInst = stream.le16(p)
        let type = stream.le16(p + 2)
        let len = Int(stream.le32(p + 4))
        let start = p + 8
        var end = start + len
        if end > stream.count { end = stream.count }
        return Rec(type: type, inst: verInst >> 4, start: start, end: end)
    }

    private func children(of r: Rec, visit: (Rec) -> Void) {
        var p = r.start
        while p + 8 <= r.end {
            guard let c = record(at: p) else { break }
            visit(c)
            p = c.end
        }
    }

    private func parse() {
        guard let doc = record(at: 0) else { return }
        if doc.type == 1001 || doc.type == 1000 {
            readDocumentAtom(doc)
        }
        if ProcessInfo.processInfo.environment["QY_DEBUG"] != nil {
            FileHandle.standardError.write("PptDebug: doc=\(doc.start)..\(doc.end) 流长=\(stream.count)\n".data(using: .utf8) ?? Data())
        }
        // 顶层：DocumentContainer(1000) 里找 SlideListWithText(4080) —— 这是文字的正规住址，
        // 顺序就是放映顺序，且不含母版占位符。
        walk(doc, depth: 0)

        // 列表里没文字时，退到「按 SlideContainer 逐页捞」
        if slideTexts.isEmpty || slideTexts.allSatisfy({ $0.isEmpty }) {
            var perSlide: [[String]] = []
            var p = doc.end
            while p + 8 <= stream.count {
                guard let r = record(at: p) else { break }
                if r.type == 1006 { perSlide.append(textsInside(r, depth: 0)) }
                p = r.end
                if r.end <= r.start { break }
            }
            if !perSlide.isEmpty { slideTexts = perSlide }
        }
        // 还是不行的，全文档扫一遍（兜底）
        if slideTexts.isEmpty || slideTexts.allSatisfy({ $0.isEmpty }) {
            fallbackFromSlides(doc)
        }
        slideTitles = slideTexts.map { texts in
            texts.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        }
    }

    private func readDocumentAtom(_ doc: Rec) {
        // DocumentAtom: 前 8 字节是幻灯片尺寸（单位 1/576 英寸）
        var p = doc.start
        while p + 8 <= doc.end {
            guard let c = record(at: p) else { break }
            if c.type == 1001 {
                let cx = Int(stream.le32(c.start))
                let cy = Int(stream.le32(c.start + 4))
                if cx > 0, cy > 0 {
                    slideWidthPt = Double(cx) / 6.0 * 0.75
                    slideHeightPt = Double(cy) / 6.0 * 0.75
                }
                return
            }
            p = c.end
        }
    }

    private func walk(_ r: Rec, depth: Int) {
        guard depth < 12 else { return }
        children(of: r) { c in
            // 4080 的实例号决定这份清单属于谁：0=幻灯片，1=母版，2=备注
            if c.type == 4080 && c.inst == 0 {
                readSlideList(c)
            } else if isContainer(c.type) {
                walk(c, depth: depth + 1)
            }
        }
    }

    private func isContainer(_ type: UInt16) -> Bool {
        // 0xF000 以上是 OfficeArt(Escher) 记录，ClientTextbox(0xF00D) 里才是文字
        if type >= 0xF000 { return true }
        switch type {
        case 1000, 1006, 1007, 1008, 1010, 1016, 1024, 1025, 1026, 1033, 1035, 1036, 1200, 2000:
            return true
        default:
            return false
        }
    }

    private func readSlideList(_ list: Rec) {
        var current: [String] = []
        var sawAtom = false

        func flush() {
            if sawAtom {
                slideTexts.append(current)
                current = []
                sawAtom = false
            }
        }

        children(of: list) { c in
            switch c.type {
            case 1011:   // SlidePersistAtom：新的一页开始
                flush()
                sawAtom = true
            case 4000:   // TextCharsAtom（UTF-16LE）
                current.append(contentsOf: splitText(decodeUTF16(c)))
            case 4008:   // TextBytesAtom（单字节）
                current.append(contentsOf: splitText(decodeBytes(c)))
            case 4026:   // CString（单字节）
                current.append(contentsOf: splitText(decodeBytes(c)))
            default:
                break
            }
        }
        flush()
    }

    /// 递归收集一条记录里的文字（TextCharsAtom / CString）
    private func textsInside(_ r: Rec, depth: Int) -> [String] {
        guard depth < 10 else { return [] }
        var out: [String] = []
        children(of: r) { c in
            switch c.type {
            case 4000: out.append(contentsOf: splitText(decodeUTF16(c)))
            case 4008: out.append(contentsOf: splitText(decodeBytes(c)))   // TextBytesAtom（单字节）
            case 4026: out.append(contentsOf: splitText(decodeBytes(c)))   // CString
            default:
                if isContainer(c.type) { out.append(contentsOf: textsInside(c, depth: depth + 1)) }
            }
        }
        return out
    }

    /// 兜底：直接从每页的 SlideContainer 里捞文字
    private func fallbackFromSlides(_ doc: Rec) {
        var found: [[String]] = []
        children(of: doc) { c in
            guard c.type == 1006 || c.type == 2000 else { return }
            var texts: [String] = []
            func scan(_ r: Rec, _ depth: Int) {
                guard depth < 10 else { return }
                children(of: r) { s in
                    if s.type == 4000 {
                        texts.append(contentsOf: splitText(decodeUTF16(s)))
                    } else if s.type == 4026 {
                        texts.append(contentsOf: splitText(decodeBytes(s)))
                    } else if isContainer(s.type) {
                        scan(s, depth + 1)
                    }
                }
            }
            scan(c, 0)
            if !texts.isEmpty { found.append(texts) }
        }
        if !found.isEmpty { slideTexts = found }
    }

    // MARK: - 解码

    private func decodeUTF16(_ r: Rec) -> String {
        let n = (r.end - r.start) / 2
        guard n > 0 else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(n)
        for i in 0..<n { units.append(stream.le16(r.start + i * 2)) }
        return String(decoding: units, as: UTF16.self)
    }

    private func decodeBytes(_ r: Rec) -> String {
        let bytes = stream.slice(r.start, r.end - r.start)
        if let s = String(data: Data(bytes), encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) {
            return s
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// \r 分段，\v 是软换行；去掉控制字符与空段
    private func splitText(_ s: String) -> [String] {
        s.replacingOccurrences(of: "\u{0B}", with: "\n")
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.replacingOccurrences(of: "\u{0}", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
