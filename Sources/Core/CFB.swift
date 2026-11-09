import Foundation

/* OLE2 / CFB（Compound File Binary）容器读取。
 *
 * .doc / .xls / .ppt（97-2003 二进制）以及 WPS 自家的 .wps / .et / .dps，
 * 外面都套着同一层"文件里的文件系统"：FAT 表 + 目录项 + 迷你流。
 * 这里只做一件事 —— 按名字把一条流完整取出来；具体格式各自再解析。
 */

final class CFB {
    struct Entry {
        let name: String
        let type: UInt8          // 1=storage 2=stream 5=root
        let start: UInt32
        let size: UInt64
    }

    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    private static let freeSect: UInt32 = 0xFFFF_FFFF
    private static let endOfChain: UInt32 = 0xFFFF_FFFE

    private let bytes: [UInt8]
    private let sectorSize: Int
    private let miniSize: Int
    private let miniCutoff: UInt32

    private var fat: [UInt32] = []
    private var miniFat: [UInt32] = []
    private var dirs: [Entry] = []
    private var miniStream: [UInt8] = []
    private var lookup: [String: Int] = [:]

    static func looksLike(_ head: ArraySlice<UInt8>) -> Bool {
        head.count >= 8 && Array(head.prefix(8)) == signature
    }

    init?(_ raw: [UInt8]) {
        guard raw.count >= 512, CFB.looksLike(raw[0...]) else { return nil }
        let shift = Int(CFB.u16(raw, 30))
        guard shift >= 7, shift <= 16 else { return nil }
        bytes = raw
        sectorSize = 1 << shift
        miniSize = 1 << Int(CFB.u16(raw, 32))
        miniCutoff = CFB.u32(raw, 56)
        guard sectorSize >= 128, miniSize >= 16 else { return nil }

        loadFAT()
        loadDirectory()
        loadMiniFAT()
    }

    // MARK: - 对外

    var streamNames: [String] { dirs.filter { $0.type == 2 }.map(\.name) }

    func has(_ name: String) -> Bool { lookup[name.lowercased()] != nil }

    func stream(_ name: String) -> [UInt8]? {
        guard let idx = lookup[name.lowercased()] else { return nil }
        let e = dirs[idx]
        guard e.type == 2 else { return nil }
        if e.size == 0 { return [] }
        if e.size < UInt64(miniCutoff) {
            return readMini(start: e.start, size: Int(e.size))
        }
        return readChain(start: e.start, size: Int(e.size))
    }

    /// 有些生成器把流名写成 "Workbook" 或 "Book"，统一按候选名找
    func firstStream(among names: [String]) -> [UInt8]? {
        for n in names {
            if let d = stream(n) { return d }
        }
        return nil
    }

    // MARK: - 基本读取

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        guard o >= 0, o + 2 <= b.count else { return 0 }
        return UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= b.count else { return 0 }
        return UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        guard o >= 0, o + 8 <= b.count else { return 0 }
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = (v << 8) | UInt64(b[o + i]) }
        return v
    }

    private func sectorOffset(_ sid: UInt32) -> Int {
        // 头部占一个扇区（v3 = 512，v4 也按 4096 对齐）
        (Int(sid) + 1) * sectorSize
    }

    private func sector(_ sid: UInt32) -> [UInt8] {
        let off = sectorOffset(sid)
        guard off >= 0, off + sectorSize <= bytes.count else { return [] }
        return Array(bytes[off..<(off + sectorSize)])
    }

    // MARK: - FAT

    private func loadFAT() {
        var ids: [UInt32] = []
        // 头部自带的 109 个 DIFAT 项
        for i in 0..<109 {
            let v = CFB.u32(bytes, 76 + i * 4)
            if v == CFB.freeSect || v == CFB.endOfChain { continue }
            ids.append(v)
        }
        // 不够就跟 DIFAT 扇区链
        var difat = CFB.u32(bytes, 68)
        let difatCount = Int(CFB.u32(bytes, 72))
        var hops = 0
        while difat != CFB.freeSect, difat != CFB.endOfChain, hops < max(difatCount, 0) + 16 {
            let sec = sector(difat)
            if sec.isEmpty { break }
            let per = sectorSize / 4 - 1
            for i in 0..<per {
                let v = CFB.u32(sec, i * 4)
                if v == CFB.freeSect || v == CFB.endOfChain { continue }
                ids.append(v)
            }
            difat = CFB.u32(sec, per * 4)
            hops += 1
        }
        let declared = Int(CFB.u32(bytes, 44))
        if declared > 0, declared < ids.count { ids = Array(ids.prefix(declared)) }

        for sid in ids {
            let sec = sector(sid)
            if sec.isEmpty { continue }
            var i = 0
            while i + 4 <= sec.count {
                fat.append(CFB.u32(sec, i))
                i += 4
            }
        }
    }

    private func chain(from start: UInt32, table: [UInt32], limit: Int) -> [UInt32] {
        var out: [UInt32] = []
        var cur = start
        var hops = 0
        let cap = limit > 0 ? limit : max(table.count, 1)
        while cur != CFB.endOfChain, cur != CFB.freeSect, Int(cur) < table.count, hops <= cap {
            out.append(cur)
            cur = table[Int(cur)]
            hops += 1
        }
        return out
    }

    private func readChain(start: UInt32, size: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(size)
        for sid in chain(from: start, table: fat, limit: fat.count) {
            let sec = sector(sid)
            if sec.isEmpty { break }
            out.append(contentsOf: sec)
            if out.count >= size { break }
        }
        if out.count > size { out.removeLast(out.count - size) }
        return out
    }

    // MARK: - 目录

    private func loadDirectory() {
        let start = CFB.u32(bytes, 48)
        var raw: [UInt8] = []
        for sid in chain(from: start, table: fat, limit: fat.count) {
            let sec = sector(sid)
            if sec.isEmpty { break }
            raw.append(contentsOf: sec)
        }
        var i = 0
        while i + 128 <= raw.count {
            let nameLen = Int(CFB.u16(raw, i + 64))
            let type = raw[i + 66]
            var name = ""
            if nameLen >= 2, nameLen <= 64 {
                var units: [UInt16] = []
                var p = i
                while p + 2 <= i + nameLen - 2 {
                    units.append(CFB.u16(raw, p))
                    p += 2
                }
                name = String(decoding: units, as: UTF16.self)
            }
            let entry = Entry(name: name, type: type,
                              start: CFB.u32(raw, i + 116),
                              size: CFB.u64(raw, i + 120))
            dirs.append(entry)
            if type == 2, !name.isEmpty {
                lookup[name.lowercased()] = dirs.count - 1
            }
            i += 128
        }
        // 根项指向迷你流的容器
        if let root = dirs.first, root.type == 5, root.size > 0 {
            miniStream = readChain(start: root.start, size: Int(root.size))
        }
    }

    private func loadMiniFAT() {
        let start = CFB.u32(bytes, 60)
        if start == CFB.endOfChain || start == CFB.freeSect { return }
        for sid in chain(from: start, table: fat, limit: fat.count) {
            let sec = sector(sid)
            if sec.isEmpty { break }
            var i = 0
            while i + 4 <= sec.count {
                miniFat.append(CFB.u32(sec, i))
                i += 4
            }
        }
    }

    private func readMini(start: UInt32, size: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(size)
        for sid in chain(from: start, table: miniFat, limit: miniFat.count) {
            let off = Int(sid) * miniSize
            guard off >= 0, off + miniSize <= miniStream.count else { break }
            out.append(contentsOf: miniStream[off..<(off + miniSize)])
            if out.count >= size { break }
        }
        if out.count > size { out.removeLast(out.count - size) }
        return out
    }
}

// MARK: - 字节读取小工具（各格式解析共用）

extension Array where Element == UInt8 {
    func le16(_ o: Int) -> UInt16 {
        guard o >= 0, o + 2 <= count else { return 0 }
        return UInt16(self[o]) | (UInt16(self[o + 1]) << 8)
    }
    func le32(_ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= count else { return 0 }
        return UInt32(self[o]) | (UInt32(self[o + 1]) << 8)
            | (UInt32(self[o + 2]) << 16) | (UInt32(self[o + 3]) << 24)
    }
    func le64(_ o: Int) -> UInt64 {
        guard o >= 0, o + 8 <= count else { return 0 }
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = (v << 8) | UInt64(self[o + i]) }
        return v
    }
    func i32(_ o: Int) -> Int32 { Int32(bitPattern: le32(o)) }

    func slice(_ start: Int, _ len: Int) -> [UInt8] {
        guard start >= 0, len > 0, start < count else { return [] }
        return Array(self[start..<Swift.min(count, start + len)])
    }

    /// CFB 里流的名字是 UTF-16LE
    func utf16le(_ start: Int, chars: Int) -> String {
        guard start >= 0, chars > 0 else { return "" }
        var units: [UInt16] = []
        var p = start
        for _ in 0..<chars {
            guard p + 2 <= count else { break }
            units.append(le16(p))
            p += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}
