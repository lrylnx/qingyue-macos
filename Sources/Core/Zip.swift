import Foundation

/* ZIP 读写。只支持 Office 用的那部分：stored(0) / deflate(8)，无加密、无分卷。
 * zip64 通过读取 zip64 extra 兜住 —— 大文件（>4GB 或 >65535 条目）在 Office 里少见，
 * 但一个 200MB 的 xlsx 完全可能触发 4GB 偏移字段，所以顺带支持一下。 */

@_silgen_name("lr_inflate")
private func lr_inflate(_ src: UnsafePointer<UInt8>?, _ srcLen: Int,
                        _ outLen: UnsafeMutablePointer<Int>) -> UnsafeMutablePointer<UInt8>?

@_silgen_name("lr_deflate")
private func lr_deflate(_ src: UnsafePointer<UInt8>?, _ srcLen: Int,
                        _ outLen: UnsafeMutablePointer<Int>) -> UnsafeMutablePointer<UInt8>?

@_silgen_name("lr_crc32")
private func lr_crc32(_ crc: UInt, _ buf: UnsafePointer<UInt8>?, _ len: Int) -> UInt

final class ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let modTime: UInt16
        let modDate: UInt16
    }

    private let data: [UInt8]
    private(set) var entries: [Entry] = []
    private var byName: [String: Int] = [:]

    init?(bytes: [UInt8]) {
        self.data = bytes
        guard parseCentralDirectory() else { return nil }
    }

    convenience init?(url: URL) {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(bytes: [UInt8](d))
    }

    // MARK: - 解析

    private func u16(_ o: Int) -> UInt16 {
        guard o >= 0, o + 1 < data.count else { return 0 }
        return UInt16(data[o]) | UInt16(data[o + 1]) << 8
    }
    private func u32(_ o: Int) -> UInt32 {
        guard o >= 0, o + 3 < data.count else { return 0 }
        return UInt32(data[o]) | UInt32(data[o + 1]) << 8
            | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24
    }
    private func u64(_ o: Int) -> UInt64 {
        UInt64(u32(o)) | UInt64(u32(o + 4)) << 32
    }

    private func parseCentralDirectory() -> Bool {
        // EOCD 在文件尾部，注释最长 65535
        let n = data.count
        guard n > 22 else { return false }
        var eocd = -1
        let lower = max(0, n - 22 - 65535)
        var i = n - 22
        while i >= lower {
            if data[i] == 0x50, data[i + 1] == 0x4B, data[i + 2] == 0x05, data[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { return false }

        var total = Int(u16(eocd + 10))
        var cdOffset = Int(u32(eocd + 16))

        // zip64 EOCD：先找 locator（20 字节，签名 PK\x06\x07）
        if total == 0xFFFF || cdOffset == 0xFFFF_FFFF {
            var j = eocd - 20
            while j >= 0 {
                if u32(j) == 0x0706_4B50 {
                    let z64Off = Int(u64(j + 8))
                    if z64Off >= 0, z64Off + 56 <= n, u32(z64Off) == 0x0606_4B50 {
                        total = Int(u64(z64Off + 32))
                        cdOffset = Int(u64(z64Off + 48))
                    }
                    break
                }
                j -= 1
            }
        }

        var p = cdOffset
        var count = 0
        while count < total, p + 46 <= n, u32(p) == 0x0201_4B50 {
            let method = u16(p + 10)
            let crc = u32(p + 16)
            var compSize = Int(u32(p + 20))
            var uncompSize = Int(u32(p + 24))
            let nameLen = Int(u16(p + 28))
            let extraLen = Int(u16(p + 30))
            let commentLen = Int(u16(p + 32))
            let modTime = u16(p + 12)
            let modDate = u16(p + 14)
            var localOff = Int(u32(p + 42))

            guard p + 46 + nameLen <= n else { break }
            let nameBytes = Array(data[(p + 46)..<(p + 46 + nameLen)])
            let name = String(decoding: nameBytes, as: UTF8.self)

            // zip64 extra（header id 0x0001）
            if extraLen > 0 {
                var e = p + 46 + nameLen
                let eEnd = e + extraLen
                while e + 4 <= eEnd {
                    let hid = u16(e), hsz = Int(u16(e + 2))
                    if hid == 0x0001 {
                        var f = e + 4
                        if uncompSize == 0xFFFF_FFFF, f + 8 <= eEnd { uncompSize = Int(u64(f)); f += 8 }
                        if compSize == 0xFFFF_FFFF, f + 8 <= eEnd { compSize = Int(u64(f)); f += 8 }
                        if localOff == 0xFFFF_FFFF, f + 8 <= eEnd { localOff = Int(u64(f)); f += 8 }
                    }
                    e += 4 + hsz
                }
            }

            if !name.hasSuffix("/") {
                let e = Entry(name: name, method: method, crc: crc,
                              compressedSize: compSize, uncompressedSize: uncompSize,
                              localHeaderOffset: localOff, modTime: modTime, modDate: modDate)
                byName[name] = entries.count
                entries.append(e)
            }
            p += 46 + nameLen + extraLen + commentLen
            count += 1
        }
        return !entries.isEmpty
    }

    // MARK: - 提取

    func rawData(_ name: String) -> [UInt8]? {
        guard let idx = byName[name] else { return nil }
        let e = entries[idx]
        var p = e.localHeaderOffset
        guard p + 30 <= data.count, u32(p) == 0x0403_4B50 else { return nil }
        let nameLen = Int(u16(p + 26))
        let extraLen = Int(u16(p + 28))
        let start = p + 30 + nameLen + extraLen
        guard start + e.compressedSize <= data.count else { return nil }
        let comp = Array(data[start..<(start + e.compressedSize)])

        switch e.method {
        case 0:
            return comp
        case 8:
            var outLen = 0
            guard let out = comp.withUnsafeBufferPointer({ buf in
                lr_inflate(buf.baseAddress, buf.count, &outLen)
            }) else { return nil }
            defer { free(out) }
            return [UInt8](UnsafeBufferPointer(start: out, count: outLen))
        default:
            return nil
        }
    }

    func data(_ name: String) -> Data? {
        rawData(name).map { Data($0) }
    }

    func string(_ name: String) -> String? {
        guard let d = rawData(name) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    func exists(_ name: String) -> Bool { byName[name] != nil }

    /// 按后缀找（有些生成器不用标准路径）
    func firstName(where pred: (String) -> Bool) -> String? {
        entries.first(where: { pred($0.name) })?.name
    }
}

// MARK: - 写

enum ZipWriter {
    struct Item {
        let name: String
        let bytes: [UInt8]
    }

    /// 全 stored 模式重打包：用于「改一点内容」的场景，简单且不会破坏任何字节。
    /// 体积会变大（xlsx 里 XML 压缩率通常 10:1），所以优先用 deflate。
    static func build(_ items: [Item], compress: Bool = true) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(1 << 20)
        struct Meta { var name: [UInt8]; var crc: UInt32; var csize: Int; var usize: Int
                      var offset: Int; var method: UInt16 }
        var metas: [Meta] = []

        let (dosTime, dosDate) = dosTimestamp(Date())

        for it in items {
            let nameBytes = Array(it.name.utf8)
            let crc = it.bytes.withUnsafeBufferPointer { lr_crc32(0, $0.baseAddress, $0.count) }

            var payload = it.bytes
            var method: UInt16 = 0
            if compress, it.bytes.count > 64 {
                var outLen = 0
                if let z = it.bytes.withUnsafeBufferPointer({ buf in
                    lr_deflate(buf.baseAddress, buf.count, &outLen)
                }) {
                    let deflated = [UInt8](UnsafeBufferPointer(start: z, count: outLen))
                    free(z)
                    if deflated.count < it.bytes.count {
                        payload = deflated
                        method = 8
                    }
                }
            }

            let offset = out.count
            // 本地文件头
            appendU32(&out, 0x0403_4B50)
            appendU16(&out, 20)              // version needed
            appendU16(&out, 0)               // flags（无 UTF-8 标志也无妨，Office 用 ASCII 名）
            appendU16(&out, method)
            appendU16(&out, dosTime)
            appendU16(&out, dosDate)
            appendU32(&out, UInt32(truncatingIfNeeded: Int(crc)))
            appendU32(&out, UInt32(truncatingIfNeeded: payload.count))
            appendU32(&out, UInt32(truncatingIfNeeded: it.bytes.count))
            appendU16(&out, UInt16(nameBytes.count))
            appendU16(&out, 0)
            out.append(contentsOf: nameBytes)
            out.append(contentsOf: payload)

            metas.append(Meta(name: nameBytes, crc: UInt32(truncatingIfNeeded: Int(crc)),
                              csize: payload.count, usize: it.bytes.count,
                              offset: offset, method: method))
        }

        let cdStart = out.count
        for m in metas {
            appendU32(&out, 0x0201_4B50)
            appendU16(&out, 20)
            appendU16(&out, 20)
            appendU16(&out, 0)
            appendU16(&out, m.method)
            appendU16(&out, dosTime)
            appendU16(&out, dosDate)
            appendU32(&out, m.crc)
            appendU32(&out, UInt32(truncatingIfNeeded: m.csize))
            appendU32(&out, UInt32(truncatingIfNeeded: m.usize))
            appendU16(&out, UInt16(m.name.count))
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU32(&out, 0)
            appendU32(&out, UInt32(truncatingIfNeeded: m.offset))
            out.append(contentsOf: m.name)
        }
        let cdSize = out.count - cdStart

        appendU32(&out, 0x0605_4B50)
        appendU16(&out, 0)
        appendU16(&out, 0)
        appendU16(&out, UInt16(truncatingIfNeeded: metas.count))
        appendU16(&out, UInt16(truncatingIfNeeded: metas.count))
        appendU32(&out, UInt32(truncatingIfNeeded: cdSize))
        appendU32(&out, UInt32(truncatingIfNeeded: cdStart))
        appendU16(&out, 0)

        return Data(out)
    }

    private static func appendU16(_ a: inout [UInt8], _ v: UInt16) {
        a.append(UInt8(v & 0xFF)); a.append(UInt8((v >> 8) & 0xFF))
    }
    private static func appendU32(_ a: inout [UInt8], _ v: UInt32) {
        a.append(UInt8(v & 0xFF)); a.append(UInt8((v >> 8) & 0xFF))
        a.append(UInt8((v >> 16) & 0xFF)); a.append(UInt8((v >> 24) & 0xFF))
    }
    private static func dosTimestamp(_ d: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        // 位运算和 ?? 混在一个表达式里会让类型检查器炸掉（它要在 Int/UInt16
        // 之间反复试），所以一步步拆开写。
        let year: Int = max(1980, (c.year ?? 2024) - 1980)
        let month: Int = c.month ?? 1
        let day: Int = c.day ?? 1
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        let second: Int = c.second ?? 0
        let timeBits: Int = (hour << 11) | (minute << 5) | (second / 2)
        let dateBits: Int = (year << 9) | (month << 5) | day
        return (UInt16(truncatingIfNeeded: timeBits), UInt16(truncatingIfNeeded: dateBits))
    }
}
