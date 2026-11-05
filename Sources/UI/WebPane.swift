import SwiftUI
import WebKit
import AppKit

/// WKWebView 的 SwiftUI 包装。
///
/// 关键点：HTML 可能有几十 MB（大 xlsx），绝不能靠「比较字符串」判断要不要重载，
/// 否则每次 body 重算都要做一次全量比对。用 loadVersion 计数判断。
struct WebPane: NSViewRepresentable {
    @ObservedObject var store: Workspace

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> WKWebView {
        let conf = WKWebViewConfiguration()
        conf.userContentController.add(context.coordinator, name: "ly")
        conf.defaultWebpagePreferences.allowsContentJavaScript = true
        conf.websiteDataStore = .nonPersistent()   // 纯本地查看，不留站点数据

        let wv = WKWebView(frame: .zero, configuration: conf)
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = false
        wv.allowsMagnification = true
        wv.setValue(false, forKey: "drawsBackground")

        context.coordinator.webView = wv
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let c = context.coordinator

        if c.version != store.loadVersion {
            c.version = store.loadVersion
            wv.loadHTMLString(store.html, baseURL: nil)
        }
        if c.commandToken != store.commandToken, let cmd = store.webCommand {
            c.commandToken = store.commandToken
            c.runAfterLoad(cmd)
        }
        if c.jumpToken != store.jumpToken, let t = store.jumpTarget {
            c.jumpToken = store.jumpToken
            c.runAfterLoad("document.getElementById('\(t)')?.scrollIntoView({block:'start',behavior:'smooth'})")
        }
    }

    static func dismantleNSView(_ wv: WKWebView, coordinator: Coordinator) {
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "ly")
        wv.stopLoading()
    }

    // MARK: -

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let store: Workspace
        weak var webView: WKWebView?

        var version = -1
        var commandToken = 0
        var jumpToken = 0
        private var loading = false
        private var queued: [String] = []

        init(store: Workspace) {
            self.store = store
        }

        func runAfterLoad(_ js: String) {
            if loading {
                queued.append(js)
            } else {
                webView?.evaluateJavaScript(js)
            }
        }

        // MARK: 页面回调

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }

            switch action {
            case "editText":
                let p = body["p"] as? Int ?? -1
                let text = body["text"] as? String ?? ""
                let ok = store.applyTextEdit(paragraph: p, text: text)
                runAfterLoad("window.lyEditResult && window.lyEditResult(\(ok), \(p), \(Self.jsString(text)))")

            case "editCell":
                let r = body["r"] as? Int ?? -1
                let c = body["c"] as? Int ?? -1
                let text = body["text"] as? String ?? ""
                let ok = store.applyCellEdit(row: r, col: c, text: text)
                runAfterLoad("window.lyCellResult && window.lyCellResult(\(ok), \(r), \(c), \(Self.jsString(text)))")

            case "toggleEdit":
                break

            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            loading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loading = false
            let q = queued
            queued = []
            q.forEach { webView.evaluateJavaScript($0) }
        }

        /// 文档里的外链一律交给系统浏览器，不在这个查看器里跳走
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        static func jsString(_ s: String) -> String {
            guard let data = try? JSONEncoder().encode([s]),
                  let str = String(data: data, encoding: .utf8) else { return "\"\"" }
            return String(str.dropFirst().dropLast())
        }
    }
}
