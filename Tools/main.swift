// 命令行导出器：把 docx/xlsx/pptx 转成 HTML 落盘，方便脱离 GUI 验证渲染。
// 用法: dump <input> <output.html> [sheet-index]
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("用法: dump <input> <output.html> [sheet]\n".data(using: .utf8)!)
    exit(2)
}
let inPath = args[1]
let outPath = args[2]
let sheetIdx = args.count > 3 ? (Int(args[3]) ?? 0) : 0
let url = URL(fileURLWithPath: inPath)
let raw = (try? Data(contentsOf: url)) ?? Data()
let container = DocKind.container(of: raw)
var resolved: DocKind? = DocKind.from(url)
if container == .cfb { resolved = DocKind.legacyKind(raw) ?? resolved }

guard let kind = resolved else {
    FileHandle.standardError.write("不支持的格式\n".data(using: .utf8)!)
    exit(3)
}

var html = ""
let t0 = Date()

if container == .cfb {
    switch kind {
    case .sheet:
        guard let b = XlsWorkbook(data: raw, path: inPath) else {
            FileHandle.standardError.write("xls 打开失败\n".data(using: .utf8)!)
            exit(4)
        }
        let r = b.drawSheet(sheetIdx)
        html = Pages.sheet(b, sheetIndex: sheetIdx, name: url.lastPathComponent)
        print("老式 xls：工作表 \(b.sheets.map(\.name))，\(r.rowCount) 行 × \(r.colCount) 列，截断=\(r.truncated)")
    case .doc:
        guard let d = LegacyDoc(data: [UInt8](raw)) else {
            FileHandle.standardError.write("doc 打开失败\n".data(using: .utf8)!)
            exit(4)
        }
        html = Pages.legacyDoc(d, name: url.lastPathComponent)
        print("老式 doc：正文 \(d.html.utf8.count) 字节 HTML，默认字号 \(d.defaultBodySize.map { fmt($0) } ?? "-")pt")
    case .ppt:
        guard let p = LegacyPpt(data: [UInt8](raw)) else {
            FileHandle.standardError.write("ppt 打开失败\n".data(using: .utf8)!)
            exit(4)
        }
        html = Pages.legacyPpt(p, name: url.lastPathComponent)
        print("老式 ppt：\(p.slideTexts.count) 页，画布 \(fmt(p.slideWidthPt))×\(fmt(p.slideHeightPt))pt")
        print("每页字数: \(p.slideTexts.map { $0.joined().count })")
    }
    try html.write(toFile: outPath, atomically: true, encoding: .utf8)
    print("✓ \(outPath)  \(html.utf8.count / 1024) KB")
    exit(0)
}

switch kind {
case .doc:
    guard let d = DocxDocument(url: url) else {
        FileHandle.standardError.write("docx 打开失败\n".data(using: .utf8)!)
        exit(4)
    }
    html = Pages.docx(d, name: url.lastPathComponent, editing: false)
    print("段落数 \(d.paragraphs.count)，标题 \(d.outline.count)，页宽 \(fmt(d.pageWidthPt))pt")
case .sheet:
    guard let b = XlsxWorkbook(url: url) else {
        FileHandle.standardError.write("xlsx 打开失败\n".data(using: .utf8)!)
        exit(4)
    }
    let r = b.render(sheetIndex: sheetIdx)
    html = Pages.sheet(b, sheetIndex: sheetIdx, name: url.lastPathComponent)
    print("工作表 \(b.sheets.map(\.name))，\(r.rowCount) 行 × \(r.colCount) 列，截断=\(r.truncated)")
case .ppt:
    guard let p = PptxDocument(url: url) else {
        FileHandle.standardError.write("pptx 打开失败\n".data(using: .utf8)!)
        exit(4)
    }
    html = Pages.ppt(p, name: url.lastPathComponent)
    print("幻灯片 \(p.slidePaths.count) 页，画布 \(fmt(p.slideWidthPt))×\(fmt(p.slideHeightPt))pt")
    print("标题: \(p.slideTitles.map { String($0.prefix(14)) })")
}

try html.write(toFile: outPath, atomically: true, encoding: .utf8)
let ms = Int(Date().timeIntervalSince(t0) * 1000)
let kb = html.utf8.count / 1024
print("✓ \(outPath)  \(kb) KB  \(ms) ms")
