import Foundation

/// 文件格式判定。放在 Core 里是因为命令行导出工具也要用（不依赖 AppKit/SwiftUI）。
enum DocKind {
    case doc, sheet, ppt

    static func from(_ url: URL) -> DocKind? {
        switch url.pathExtension.lowercased() {
        case "docx", "docm", "dotx": return .doc
        case "xlsx", "xlsm", "xltx": return .sheet
        case "pptx", "pptm", "potx": return .ppt
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .doc: return "Word 文档"
        case .sheet: return "Excel 表格"
        case .ppt: return "PowerPoint 演示"
        }
    }
}
