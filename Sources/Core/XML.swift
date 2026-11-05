import Foundation

/* 手写 XML 扫描器。
 *
 * 不用 Foundation.XMLParser 的原因：那套是委托回调，要在回调里维护深度栈 +
 * 记录「这个 w:p 在原始字节里的起止位置」非常别扭，而编辑回写恰恰需要字节偏移。
 * Office 生成的 XML 极其规整（无 DTD、无处理指令），逐字节扫是最直接的路子。
 */

struct XMLTok {
    enum Kind { case open, close, text }
    var kind: Kind
    var name: String = ""
    var attrs: [String: String] = [:]
    var selfClosing: Bool = false
    var text: String = ""
    var start: Int = 0      // 字节偏移：'<' 或文本首字节
    var end: Int = 0        // 字节偏移：'>' 之后 / 文本末尾

    /// 去掉命名空间前缀后的小写名，比较时用这个
    var local: String {
        guard let c = name.firstIndex(of: ":") else { return name.lowercased() }
        return String(name[name.index(after: c)...]).lowercased()
    }

    /// 支持无前缀或任意前缀取属性，例如 attr("val") 能拿到 w:val / a:val
    func attr(_ key: String) -> String? {
        if let v = attrs[key] { return v }
        for (k, v) in attrs where k.hasSuffix(":" + key) { return v }
        return nil
    }
}

final class XMLScanner {
    let b: [UInt8]
    private(set) var i = 0

    init(_ bytes: [UInt8]) { b = bytes }
    init(_ s: String) { b = Array(s.utf8) }

    var isAtEnd: Bool { i >= b.count }

    /// 直接把游标挪到某个偏移（回写时用来跳过已知区域）
    func seek(_ offset: Int) { i = max(0, min(offset, b.count)) }

    func next() -> XMLTok? {
        while i < b.count {
            guard b[i] == 0x3C else {   // '<'
                let start = i
                while i < b.count, b[i] != 0x3C { i += 1 }
                let s = String(decoding: b[start..<i], as: UTF8.self)
                if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                return XMLTok(kind: .text, text: XMLText.decodeEntities(s), start: start, end: i)
            }

            // 注释
            if match("<!--") {
                while i + 3 < b.count, !match("-->") { i += 1 }
                i = min(b.count, i + 3)
                continue
            }
            // CDATA
            if match("<![CDATA[") {
                let start = i
                let bodyStart = i + 9
                while i + 3 <= b.count, !match("]]>") { i += 1 }
                let bodyEnd = min(i, b.count)
                i = min(b.count, i + 3)
                let s = String(decoding: b[bodyStart..<bodyEnd], as: UTF8.self)
                return XMLTok(kind: .text, text: s, start: start, end: i)
            }
            // 处理指令 / DOCTYPE
            if i + 1 < b.count, b[i + 1] == 0x3F || b[i + 1] == 0x21 {  // ? or !
                while i < b.count, b[i] != 0x3E { i += 1 }
                i = min(b.count, i + 1)
                continue
            }
            // 结束标签
            if i + 1 < b.count, b[i + 1] == 0x2F {  // '/'
                let start = i
                i += 2
                let nameStart = i
                while i < b.count, b[i] != 0x3E, !isSpace(b[i]) { i += 1 }
                let name = String(decoding: b[nameStart..<i], as: UTF8.self)
                while i < b.count, b[i] != 0x3E { i += 1 }
                i = min(b.count, i + 1)
                return XMLTok(kind: .close, name: name, start: start, end: i)
            }
            // 开始标签
            let start = i
            i += 1
            let nameStart = i
            while i < b.count, !isSpace(b[i]), b[i] != 0x3E, b[i] != 0x2F { i += 1 }
            let name = String(decoding: b[nameStart..<i], as: UTF8.self)

            var attrs: [String: String] = [:]
            var selfClosing = false
            while i < b.count {
                while i < b.count, isSpace(b[i]) { i += 1 }
                guard i < b.count else { break }
                if b[i] == 0x3E { i += 1; break }
                if b[i] == 0x2F { selfClosing = true; i += 1; continue }
                // 属性名
                let kStart = i
                while i < b.count, b[i] != 0x3D, !isSpace(b[i]), b[i] != 0x3E, b[i] != 0x2F { i += 1 }
                let key = String(decoding: b[kStart..<i], as: UTF8.self)
                while i < b.count, isSpace(b[i]) { i += 1 }
                if i < b.count, b[i] == 0x3D {   // '='
                    i += 1
                    while i < b.count, isSpace(b[i]) { i += 1 }
                    guard i < b.count else { break }
                    let quote = b[i]
                    if quote == 0x22 || quote == 0x27 {
                        i += 1
                        let vStart = i
                        while i < b.count, b[i] != quote { i += 1 }
                        let raw = String(decoding: b[vStart..<i], as: UTF8.self)
                        attrs[key] = XMLText.decodeEntities(raw)
                        i = min(b.count, i + 1)
                    } else {
                        let vStart = i
                        while i < b.count, !isSpace(b[i]), b[i] != 0x3E { i += 1 }
                        attrs[key] = XMLText.decodeEntities(
                            String(decoding: b[vStart..<i], as: UTF8.self))
                    }
                } else if !key.isEmpty {
                    attrs[key] = ""
                }
            }
            return XMLTok(kind: .open, name: name, attrs: attrs,
                          selfClosing: selfClosing, start: start, end: i)
        }
        return nil
    }

    private func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    private func match(_ s: String) -> Bool {
        let sb = Array(s.utf8)
        guard i + sb.count <= b.count else { return false }
        for k in 0..<sb.count where b[i + k] != sb[k] { return false }
        return true
    }
}

enum XMLText {
    /// 解码 &lt; &gt; &amp; &quot; &apos; &#NN; &#xNN;
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = String()
        out.reserveCapacity(s.count)
        var it = s.makeIterator()
        var buf: [Character] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c != "&" {
                out.append(c)
                i = s.index(after: i)
                continue
            }
            // 找分号，最多 10 个字符
            var j = s.index(after: i)
            var limit = 0
            var semi: String.Index? = nil
            while j < s.endIndex, limit < 12 {
                if s[j] == ";" { semi = j; break }
                if s[j] == "&" || s[j] == " " { break }
                j = s.index(after: j)
                limit += 1
            }
            guard let semi else { out.append(c); i = s.index(after: i); continue }
            let body = String(s[s.index(after: i)..<semi])
            var replaced: String? = nil
            switch body {
            case "lt": replaced = "<"
            case "gt": replaced = ">"
            case "amp": replaced = "&"
            case "quot": replaced = "\""
            case "apos": replaced = "'"
            case "nbsp": replaced = "\u{00A0}"
            default:
                if body.hasPrefix("#") {
                    let num = String(body.dropFirst())
                    var code: UInt32? = nil
                    if num.hasPrefix("x") || num.hasPrefix("X") {
                        code = UInt32(num.dropFirst(), radix: 16)
                    } else {
                        code = UInt32(num)
                    }
                    if let code, let scalar = Unicode.Scalar(code) {
                        replaced = String(Character(scalar))
                    }
                }
            }
            if let r = replaced { out.append(r) } else { out.append("&"); out += body; out.append(";") }
            i = s.index(after: semi)
        }
        return out
    }

    static func escape(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count + 8)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }
}

// MARK: - 关系文件

/// 解析 *.xml.rels → { "rId5": "media/image1.png" }（相对 base 目录）
struct Relationships {
    private var map: [String: String] = [:]

    init?(xml: String?, basePath: String) {
        guard let xml else { return nil }
        let sc = XMLScanner(xml)
        let baseDir: String = {
            guard let slash = basePath.lastIndex(of: "/") else { return "" }
            return String(basePath[..<slash]) + "/"
        }()
        while let t = sc.next() {
            guard t.kind == .open, t.local == "relationship",
                  let id = t.attr("Id"), let target = t.attr("Target") else { continue }
            if t.attr("TargetMode") == "External" { continue }
            if target.hasPrefix("/") {
                map[id] = String(target.dropFirst())
            } else if target.hasPrefix("http") {
                continue
            } else {
                map[id] = normalize(baseDir + target)
            }
        }
    }

    subscript(id: String) -> String? { map[id] }

    /// 折叠 "a/../b" 这类路径
    private func normalize(_ p: String) -> String {
        var parts: [String] = []
        for c in p.split(separator: "/") {
            if c == "." { continue }
            if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(String(c))
        }
        return parts.joined(separator: "/")
    }

    static func load(_ zip: ZipArchive, path: String) -> Relationships? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let dir = String(path[..<slash])
        let file = String(path[(path.index(after: slash))...])
        return Relationships(xml: zip.string("\(dir)/_rels/\(file).rels"), basePath: path)
    }
}
