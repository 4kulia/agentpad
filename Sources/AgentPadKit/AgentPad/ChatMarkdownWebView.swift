import AppKit
import WebKit

/// Where chat Markdown is shown (DESIGN-F7, 3 and 5). The page is the
/// renderer's `.chat` output loaded as a string; nothing else ever loads in
/// it. A link leaves only through `MarkdownRenderer.chatLinkTarget` to the
/// system browser, and every other way WebKit has of following or fetching
/// a URL is closed: navigation, new windows, link preview, menu items.
final class ChatMarkdownNavigation: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// Opens a checked link; the system browser outside tests.
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// A chat web view with this navigation as its only way out. The view
    /// holds its delegates weakly: keep the navigation alive with it.
    func makeWebView() -> ChatWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let view = ChatWebView(frame: .zero, configuration: config)
        view.allowsLinkPreview = false
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        view.navigationDelegate = self
        view.uiDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    /// `baseURL: nil` puts the page at about:blank: relative paths resolve to nothing.
    func load(_ markdown: String, into view: WKWebView) {
        view.loadHTMLString(MarkdownRenderer.page(body: MarkdownRenderer.html(markdown, mode: .chat), mode: .chat), baseURL: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(policy(for: action.navigationType, url: action.request.url))
    }

    /// Only the page itself loads; a clicked link is cancelled here and,
    /// if it passes the check again, opened outside.
    func policy(for type: WKNavigationType, url: URL?) -> WKNavigationActionPolicy {
        switch type {
        case .other where url?.absoluteString == "about:blank":
            return .allow
        case .linkActivated:
            if let url, let target = MarkdownRenderer.chatLinkTarget(url) { open(target) }
            return .cancel
        default:
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}

/// Its context menu keeps copying only: "Open Link", "Download Linked
/// File", "Share" and the like reach a URL without asking the delegate.
final class ChatWebView: WKWebView {
    static let keptMenuItems: Set<String> = ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierCopyLink"]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        Self.trim(menu)
        super.willOpenMenu(menu, with: event)
    }

    static func trim(_ menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem && !keptMenuItems.contains(item.identifier?.rawValue ?? "") {
            menu.removeItem(item)
        }
        for (index, item) in menu.items.enumerated().reversed() where item.isSeparatorItem && index > 0 && menu.items[index - 1].isSeparatorItem {
            menu.removeItem(item)
        }
        while let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }
}
