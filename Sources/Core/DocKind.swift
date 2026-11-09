import Foundation

/// 文件格式判定。放在 Core 里是因为命令行导出工具也要用（不依赖 AppKit/SwiftUI）。
enum DocKind {
    case doc, sheet, ppt

    /// 后缀 → 想打开成哪一类。老式二进制后缀也算在内，具体解析路径由容器决定。
    static func from(_ url: URL) -> DocKind? {
        switch url.pathExtension.lowercased() {
        case "docx", "docm", "dotx", "doc", "dot", "wps": return .doc
        case "xlsx", "xlsm", "xltx", "xls", "xlt", "et": return .sheet
        case "pptx", "pptm", "potx", "ppt", "pot", "pps", "dps": return .ppt
        default: return nil
        }
    }

    /// 97-2003 那一代（含 WPS 的 .wps/.et/.dps）——外面都是 OLE2 复合文档
    static func isLegacyExtension(_ ext: String) -> Bool {
        ["doc", "dot", "wps", "xls", "xlt", "et", "ppt", "pot", "pps", "dps"].contains(ext)
    }

    enum Container {
        case zip      // OOXML：docx / xlsx / pptx
        case cfb      // OLE2：doc / xls / ppt / wps / et / dps
        case unknown
    }

    /// 判断容器必须看字节，不能看后缀 —— 见过太多 .xls 其实是 xlsx、或者反过来
    static func container(of data: Data) -> Container {
        let head = [UInt8](data.prefix(8))
        guard head.count >= 4 else { return .unknown }
        if head[0] == 0x50, head[1] == 0x4B, head[2] == 0x03, head[3] == 0x04 { return .zip }
        if head.count >= 8, CFB.looksLike(head[0...]) { return .cfb }
        return .unknown
    }

    var label: String {
        switch self {
        case .doc: return "Word 文档"
        case .sheet: return "Excel 表格"
        case .ppt: return "PowerPoint 演示"
        }
    }

    /// 老式二进制文件靠**里面的流名**判断类型，不看后缀。
    /// 认得出 WordDocument / Workbook / PowerPoint Document 三家的主文档流。
    static func legacyKind(_ data: Data) -> DocKind? {
        guard let cfb = CFB([UInt8](data)) else { return nil }
        let names = Set(cfb.streamNames.map { $0.lowercased() })
        if names.contains("worddocument") { return .doc }
        if names.contains("powerpoint document") { return .ppt }
        if names.contains("workbook") || names.contains("book") { return .sheet }
        return nil
    }
}
