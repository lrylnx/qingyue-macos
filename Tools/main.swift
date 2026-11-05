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

guard let kind = DocKind.from(url) else {
    FileHandle.standardError.write("不支持的格式\n".data(using: .utf8)!)
    exit(3)
}

var html = ""
let t0 = Date()

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
