import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers
import Combine

final class Workspace: ObservableObject {
    static let shared = Workspace()

    @Published var url: URL?
    @Published var kind: DocKind?
    @Published var displayName: String = "轻阅"
    @Published var html: String = ""
    @Published var loadVersion: Int = 0

    @Published var outline: [OutlineItem] = []
    @Published var sheets: [SheetRef] = []
    @Published var currentSheet: Int = 0
    @Published var slideTitles: [String] = []
    @Published var slideCount: Int = 0
    @Published var sheetRows: Int = 0
    @Published var sheetCols: Int = 0

    @Published var editingEnabled = false
    @Published var isDirty = false
    @Published var statusMessage: String = ""
    @Published var lastError: String?
    @Published var isLoading = false

    @Published var showSidebar = true
    @Published var showInfo = false

    /// 大纲滚动：改成自增计数器，避免重复点同一项没反应
    @Published var jumpTarget: String?
    @Published var jumpToken = 0

    /// 一次性下发给网页的命令（JS 片段），配合 commandToken 触发
    @Published var webCommand: String?
    @Published var commandToken = 0

    private var doc: DocxDocument?
    private var book: XlsxWorkbook?
    private var deck: PptxDocument?
    private var pendingData: Data?

    var isEmpty: Bool { url == nil }

    /// 侧边栏的视图身份：换文档/换类型时必须变化，用来强制侧边栏整块重建。
    /// 见 RootView 里 SidebarView 的 .id(store.sideIdentity) 注释。
    var sideIdentity: String {
        let k: String
        switch kind {
        case .doc:  k = "doc"
        case .sheet: k = "sheet"
        case .ppt:  k = "ppt"
        case .none: k = "none"
        }
        return k + "|" + (url?.path ?? "-")
    }

    // MARK: 打开

    func open(_ url: URL) {
        guard let k = DocKind.from(url) else {
            lastError = "不支持这个格式：.\(url.pathExtension)\n目前只支持 docx / xlsx / pptx。"
            return
        }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        self.url = url
        kind = k
        displayName = url.lastPathComponent
        isDirty = false
        pendingData = nil
        outline = []
        sheets = []
        slideTitles = []
        slideCount = 0
        currentSheet = 0
        editingEnabled = false

        switch k {
        case .doc:
            guard let d = DocxDocument(url: url) else {
                fail("这个 docx 打不开，可能已损坏或是旧版 .doc 改了后缀。")
                return
            }
            doc = d
            outline = d.outline
            html = Pages.docx(d, name: url.lastPathComponent, editing: false)
        case .sheet:
            guard let b = XlsxWorkbook(url: url) else {
                fail("这个 xlsx 打不开，可能已损坏或是旧版 .xls 改了后缀。")
                return
            }
            book = b
            sheets = b.sheets
            renderSheet(0)
        case .ppt:
            guard let p = PptxDocument(url: url) else {
                fail("这个 pptx 打不开，可能已损坏或是旧版 .ppt 改了后缀。")
                return
            }
            deck = p
            slideCount = p.slidePaths.count
            html = Pages.ppt(p, name: url.lastPathComponent)
            slideTitles = p.slideTitles
        }
        loadVersion += 1
        statusMessage = ""
    }

    private func fail(_ msg: String) {
        lastError = msg
        html = simplePage(msg)
        loadVersion += 1
        url = nil
    }

    private func simplePage(_ msg: String) -> String {
        HTMLShell.page(.doc, body: """
<div style="display:flex;height:70vh;align-items:center;justify-content:center;padding:40px">
  <div style="max-width:520px;color:#5A6068;font-size:14px;line-height:1.8;text-align:center">
    \(XMLText.escape(msg))
  </div>
</div>
""")
    }

    // MARK: 表格

    func renderSheet(_ index: Int) {
        guard let b = book else { return }
        currentSheet = index
        let r = b.render(sheetIndex: index)
        sheetRows = r.rowCount
        sheetCols = r.colCount
        html = Pages.sheet(b, sheetIndex: index, name: displayName)
        loadVersion += 1
    }

    // MARK: 编辑

    func applyTextEdit(paragraph p: Int, text: String) -> Bool {
        guard let d = doc, let url else { return false }
        guard let data = d.applyText(text, toParagraph: p) else { return false }
        pendingData = data
        isDirty = true
        statusMessage = "已修改，按 ⌘S 保存"
        _ = url
        return true
    }

    func applyCellEdit(row: Int, col: Int, text: String) -> Bool {
        guard let b = book, let data = b.applyCell(sheet: currentSheet, row: row, col: col, text: text) else {
            return false
        }
        pendingData = data
        isDirty = true
        statusMessage = "已修改，按 ⌘S 保存"
        return true
    }

    func save() {
        guard let url, let data = pendingData else { return }
        do {
            // 先写到同目录临时文件再原子替换，避免写一半断电把原文件毁了
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).lytmp")
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            isDirty = false
            statusMessage = "已保存"
            // 重新解析，让界面反映真实落盘内容
            open(url)
        } catch {
            lastError = "保存失败：\(error.localizedDescription)"
        }
    }

    func saveAs() {
        guard let data = pendingData ?? url.flatMap({ try? Data(contentsOf: $0) }),
              let src = url else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = src.lastPathComponent
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let dest = panel.url {
            do {
                try data.write(to: dest)
                statusMessage = "已另存为 \(dest.lastPathComponent)"
            } catch {
                lastError = "另存失败：\(error.localizedDescription)"
            }
        }
    }

    func toggleEdit() {
        guard kind == .doc, let d = doc, let url else { return }
        editingEnabled.toggle()
        html = Pages.docx(d, name: url.lastPathComponent, editing: editingEnabled)
        loadVersion += 1
    }

    func jump(to anchor: String) {
        jumpTarget = anchor
        jumpToken += 1
    }

    func focusSearch() {
        webCommand = "var q=document.getElementById('q'); if(q){q.focus();q.select();}"
        commandToken += 1
    }

    func step(_ delta: Int) {
        webCommand = "window.lyStep && window.lyStep(\(delta))"
        commandToken += 1
    }

    func gotoSlide(_ n: Int) {
        webCommand = "window.lyGo && window.lyGo(\(n))"
        commandToken += 1
    }

    func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let exts = ["docx", "docm", "dotx", "xlsx", "xlsm", "xltx", "pptx", "pptm", "potx"]
        panel.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
        if panel.allowedContentTypes.isEmpty {
            panel.allowedFileTypes = exts
        }
        panel.message = "选择 docx / xlsx / pptx 文件"
        panel.prompt = "打开"
        if panel.runModal() == .OK, let u = panel.url { open(u) }
    }

    func revealInFinder() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openExternally() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    func closeDocument() {
        doc = nil; book = nil; deck = nil
        url = nil; kind = nil
        html = ""; outline = []; sheets = []; slideTitles = []
        pendingData = nil; isDirty = false
        displayName = "轻阅"
        loadVersion += 1
    }
}
