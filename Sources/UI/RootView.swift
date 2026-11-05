import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

// MARK: - 入口

@main
struct LightReadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Workspace.shared

    var body: some Scene {
        // 用 Window 而不是 WindowGroup：这是查看器，一个窗口就够。
        // WindowGroup 下每 open 一次文件就多一个窗口，而所有窗口共享同一个
        // Workspace，于是后开的文档会把前面窗口的内容一起换掉 —— 看起来像
        // "边栏里的东西串了"。单实例窗口从根上消掉这个状态。
        Window("轻阅", id: "main") {
            RootView(store: store)
                .frame(minWidth: 640, minHeight: 460)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1120, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开…") { store.pickFile() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存") { store.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!store.isDirty)
                Button("另存为…") { store.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(store.url == nil)
            }
            CommandGroup(after: .textEditing) {
                Divider()
                Button("查找") { store.focusSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(store.isEmpty)
                Button("切换侧边栏") {
                    withAnimation(.easeInOut(duration: 0.16)) { store.showSidebar.toggle() }
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
            }
            CommandGroup(after: .toolbar) {
                Button("上一页") { store.step(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                    .disabled(store.kind != .ppt)
                Button("下一页") { store.step(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command])
                    .disabled(store.kind != .ppt)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        DispatchQueue.main.async { Workspace.shared.open(first) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - 根视图

struct RootView: View {
    @ObservedObject var store: Workspace
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if store.showSidebar && !store.isEmpty {
                    SidebarView(store: store)
                        .frame(width: 214)
                        .transition(.move(edge: .leading))
                    Divider()
                }
                ZStack {
                    if store.isEmpty && store.lastError == nil {
                        EmptyState(store: store, dropTargeted: dropTargeted)
                    } else {
                        WebPane(store: store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            StatusBar(store: store)
        }
        .navigationTitle(store.isEmpty ? "轻阅" : store.displayName)
        .toolbar { toolbarContent }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { store.open(url) }
            }
            return true
        }
        .alert("打不开", isPresented: Binding(
            get: { store.lastError != nil && !store.isEmpty },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("好") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { store.showSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("显示/隐藏侧边栏 ⌥⌘0")
            .disabled(store.isEmpty)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if store.kind == .doc {
                Button {
                    store.toggleEdit()
                } label: {
                    Label(store.editingEnabled ? "完成" : "编辑",
                          systemImage: store.editingEnabled ? "checkmark.circle.fill" : "pencil")
                }
                .help("开启后点段落即可改字（双击任意位置都能改）")
            }

            if store.isDirty {
                Button { store.save() } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .help("⌘S")
            }

            Button { store.pickFile() } label: {
                Label("打开", systemImage: "folder")
            }
            .help("⌘O")

            Menu {
                Button("在 Finder 中显示") { store.revealInFinder() }
                    .disabled(store.url == nil)
                Button("用默认程序打开") { store.openExternally() }
                    .disabled(store.url == nil)
                Divider()
                Button("关闭文件") { store.closeDocument() }
                    .disabled(store.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 32)
        }
    }
}

// MARK: - 侧边栏

struct SidebarView: View {
    @ObservedObject var store: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headerTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 7)

            ScrollView {
                // 用 VStack 而不是 LazyVStack：LazyVStack 会缓存离屏行，切换文档
                // 类型时旧行不会重建 —— 表现为幻灯片列表最上面挂着上一份 docx 的
                // 标题（而且丢了自己的序号）。侧边栏最多几十行，不需要懒加载。
                VStack(alignment: .leading, spacing: 1) {
                    switch store.kind {
                    case .doc: docOutline
                    case .sheet: sheetList
                    case .ppt: slideList
                    case .none: EmptyView()
                    }
                }
                // 换文档就整块重建。光靠 switch 各分支是不够的：三个 ForEach 落在
                // 同一个 ViewBuilder 位置上，SwiftUI 按位置复用身份，于是幻灯片列表
                // 的第一行会显示成上一份 docx 的标题、且丢掉自己的序号。
                // .id 绑到"当前文档"上，任何一次换文件都从零开始布局。
                .id(store.sideIdentity)
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var headerTitle: String {
        switch store.kind {
        case .doc: return store.outline.isEmpty ? "文档" : "目录 · \(store.outline.count)"
        case .sheet: return "工作表 · \(store.sheets.count)"
        case .ppt: return "幻灯片 · \(store.slideCount)"
        case .none: return ""
        }
    }

    @ViewBuilder
    private var docOutline: some View {
        if store.outline.isEmpty {
            Text("这份文档没有设置标题样式，\n所以没有目录。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .lineSpacing(3)
        } else {
            ForEach(Array(store.outline.enumerated()), id: \.offset) { _, item in
                Button {
                    store.jump(to: item.anchor)
                } label: {
                    HStack(spacing: 0) {
                        Text(item.text)
                            .font(.system(size: item.level <= 2 ? 12.5 : 12,
                                          weight: item.level == 1 ? .semibold : .regular))
                            .foregroundStyle(item.level == 1 ? .primary : .secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, CGFloat(max(0, item.level - 1)) * 11)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SideRowStyle())
            }
        }
    }

    @ViewBuilder
    private var sheetList: some View {
        ForEach(Array(store.sheets.enumerated()), id: \.offset) { idx, s in
            Button {
                store.renderSheet(idx)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 11))
                        .foregroundStyle(idx == store.currentSheet ? Color.accentColor : .secondary)
                    Text(s.name)
                        .font(.system(size: 12.5, weight: idx == store.currentSheet ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if s.hidden {
                        Text("隐藏").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(SideRowStyle(selected: idx == store.currentSheet))
        }
    }

    @ViewBuilder
    private var slideList: some View {
        ForEach(0..<store.slideCount, id: \.self) { i in
            Button {
                store.gotoSlide(i + 1)
            } label: {
                HStack(spacing: 8) {
                    Text("\(i + 1)")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .trailing)
                    Text(i < store.slideTitles.count ? store.slideTitles[i] : "第 \(i + 1) 页")
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(SideRowStyle())
        }
    }
}

struct SideRowStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color.accentColor.opacity(0.14)
                          : Color.primary.opacity(configuration.isPressed ? 0.07 : 0.0001))
            )
            .foregroundStyle(selected ? Color.accentColor : .primary)
    }
}

// MARK: - 空状态

struct EmptyState: View {
    @ObservedObject var store: Workspace
    let dropTargeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.55))

            VStack(spacing: 6) {
                Text("轻阅")
                    .font(.system(size: 19, weight: .semibold))
                Text("只看不改也能看清 · 需要时也能改两个字")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            Button {
                store.pickFile()
            } label: {
                Text("打开文件")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("或者把 .docx / .xlsx / .pptx 拖进来")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.22))
                .padding(38)
        )
    }
}

// MARK: - 状态栏

struct StatusBar: View {
    @ObservedObject var store: Workspace

    var body: some View {
        HStack(spacing: 10) {
            if !store.isEmpty {
                Text(store.kind?.label ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(store.isDirty ? Color.orange : .secondary)
            }
            if store.isDirty {
                HStack(spacing: 3) {
                    Circle().fill(Color.orange).frame(width: 5, height: 5)
                    Text("未保存").font(.system(size: 10.5)).foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 24)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var detail: String {
        switch store.kind {
        case .sheet: return "\(store.sheetRows) 行 × \(store.sheetCols) 列"
        case .ppt: return "\(store.slideCount) 页"
        case .doc: return store.outline.isEmpty ? "" : "\(store.outline.count) 个标题"
        case .none: return ""
        }
    }
}
