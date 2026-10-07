import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import WebKit

/// Read-only preview of the file selected in the tree, shown under the
/// terminal. Editing stays in the user's editor ("Open").
struct FilePreviewPanel: View {
    let model: FilePreviewModel
    let root: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.chromeSeparator).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.chromeBackground)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let url = model.url {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.chromeMuted)
                Text(url.lastPathComponent)
                    .font(Theme.display(12.5, weight: .medium))
                    .foregroundStyle(Theme.chromeForeground)
                    .lineLimit(1)
                if let location = model.sourceLocation {
                    Text(location.column.map { "Ln \(location.line), Col \($0)" } ?? "Ln \(location.line)")
                        .font(Theme.mono(10)).foregroundStyle(Theme.chromeMuted)
                }
                Text(relativeParent(url))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.chromeFaint)
                    .lineLimit(1)
                    .truncationMode(.head)
                if case .text(_, _, true, _) = model.content {
                    Text("first 5 MB")
                        .font(Theme.display(10, weight: .medium))
                        .foregroundStyle(Theme.activityAttention)
                }
                Spacer(minLength: 4)
                if hasRenderedPreview {
                    Picker("", selection: Binding(get: { model.showsMarkdownSource }, set: { model.showsMarkdownSource = $0 })) {
                        Text("Preview").tag(false)
                        Text("Source").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                HoverableIconButton(systemName: "arrow.up.forward.app", fontSize: 11, size: 22, help: "Open in default app") {
                    NSWorkspace.shared.open(url)
                }
                HoverableIconButton(systemName: "folder", fontSize: 11, size: 22, help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                HoverableIconButton(systemName: "xmark", fontSize: 11, size: 22, help: "Close preview") {
                    model.close()
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    private var hasRenderedPreview: Bool {
        switch model.content {
        case .markdown, .html: true
        default: false
        }
    }

    private func relativeParent(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().path
        if let root = root?.standardizedFileURL.path, parent.hasPrefix(root) {
            let rel = String(parent.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rel
        }
        return (parent as NSString).abbreviatingWithTildeInPath
    }

    @ViewBuilder
    private var content: some View {
        switch model.content {
        case nil:
            ProgressView().controlSize(.small)
        case .text(let text, _, _, let spans):
            CodeTextView(text: text, spans: spans, revision: model.revision, location: model.sourceLocation)
        case .markdown(let text, let html):
            if model.showsMarkdownSource {
                CodeTextView(text: text, spans: [], revision: model.revision, location: model.sourceLocation)
            } else if let url = model.url {
                MarkdownWebView(
                    html: html,
                    documentURL: url,
                    allowedRoot: root ?? url.deletingLastPathComponent(),
                    revision: model.revision,
                    onOpenLocal: { model.open($0) }
                )
            }
        case .html(let text):
            if model.showsMarkdownSource {
                CodeTextView(text: text, spans: [], revision: model.revision, location: model.sourceLocation)
            } else if let url = model.url {
                MarkdownWebView(
                    html: HTMLPreview.document(text), documentURL: url,
                    allowedRoot: url.deletingLastPathComponent(), revision: model.revision,
                    onOpenLocal: { model.open($0) }, allowsStylesheets: true
                )
            }
        case .image(let image):
            FilePreviewImageView(image: image)
        case .quickLook:
            if let url = model.url {
                QuickLookView(url: url, revision: model.revision)
            }
        case .directory:
            message("folder", "Folders aren't previewed.")
        case .unreadable(let reason):
            message("exclamationmark.triangle", reason)
        }
    }

    private func message(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 20, weight: .light)).foregroundStyle(Theme.chromeFaint)
            Text(text).font(Theme.display(12)).foregroundStyle(Theme.chromeMuted)
        }
    }
}

/// One stable view/image per decoded bitmap. No URL-backed NSImage (which
/// defers decoding until drawing), file watching, or clearing during reloads.
struct FilePreviewImageView: NSViewRepresentable {
    let image: FilePreviewModel.DecodedImage

    final class Coordinator { var image: FilePreviewModel.DecodedImage? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class ImageView: NSImageView {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
    }

    func makeNSView(context: Context) -> NSImageView {
        let view = ImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.image != image else { return }
        context.coordinator.image = image
        view.image = NSImage(cgImage: image.cgImage, size: NSSize(width: image.cgImage.width, height: image.cgImage.height))
    }
}

/// Quick Look's own view: unsupported images, PDF, office documents, audio, video.
struct QuickLookView: NSViewRepresentable {
    let url: URL
    let revision: Int

    final class Coordinator {
        var url: URL?
        var revision = -1
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        let changedURL = context.coordinator.url != url
        guard changedURL || context.coordinator.revision != revision else { return }
        context.coordinator.url = url
        context.coordinator.revision = revision
        if changedURL {
            view.previewItem = url as NSURL
        } else {
            view.refreshPreviewItem()
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
    }
}

/// Rendered Markdown. JavaScript is off. Local resources load only through
/// `agentpad-doc:`, which serves images from inside `allowedRoot` and nothing
/// else; links open externally only for http(s)/mailto, a local Markdown link
/// opens in the preview, and any other local file is revealed in Finder —
/// never launched.
struct MarkdownWebView: NSViewRepresentable {
    let html: String
    let documentURL: URL
    /// The project folder; images outside it are refused.
    let allowedRoot: URL
    let revision: Int
    let onOpenLocal: (URL) -> Void
    var allowsStylesheets = false

    static let scheme = "agentpad-doc"

    final class Coordinator: NSObject, WKNavigationDelegate {
        var revision = -1
        var onOpenLocal: (URL) -> Void = { _ in }
        let resources = LocalResourceHandler()

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url else {
                // loadHTMLString's initial document is local. HTML refreshes,
                // forms and frames must not navigate to a remote page.
                let scheme = action.request.url?.scheme
                decisionHandler(scheme == "about" || scheme == MarkdownWebView.scheme ? .allow : .cancel)
                return
            }
            decisionHandler(.cancel)
            switch url.scheme?.lowercased() {
            case "http", "https", "mailto":
                NSWorkspace.shared.open(url)
            case MarkdownWebView.scheme, "file":
                // In-page anchors stay put.
                if url.fragment != nil, url.path == webView.url?.path { return }
                let file = URL(fileURLWithPath: url.path)
                if MarkdownWebView.isMarkdown(file) {
                    onOpenLocal(file)
                } else if FileManager.default.fileExists(atPath: file.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
            default:
                break
            }
        }
    }

    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(context.coordinator.resources, forURLScheme: Self.scheme)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onOpenLocal = onOpenLocal
        context.coordinator.resources.allowedRoot = allowedRoot
        context.coordinator.resources.allowsStylesheets = allowsStylesheets
        guard context.coordinator.revision != revision else { return }
        context.coordinator.revision = revision
        // Relative paths in the page resolve against the document's folder,
        // under our scheme, so they can only reach the resource handler.
        var base = URLComponents()
        base.scheme = Self.scheme
        base.host = "local"
        base.path = documentURL.deletingLastPathComponent().path + "/"
        view.loadHTMLString(html, baseURL: base.url)
    }
}

/// Serves `agentpad-doc://local/<absolute path>` for images under the allowed
/// root only, after resolving symlinks — a README can't pull in files from
/// elsewhere on disk.
final class LocalResourceHandler: NSObject, WKURLSchemeHandler {
    var allowedRoot: URL?
    var allowsStylesheets = false
    static let maxBytes = 20 * 1024 * 1024

    /// Tasks WebKit has cancelled; they must not be answered afterwards.
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let root = allowedRoot else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let id = ObjectIdentifier(task)
        let path = url.path
        let allowsStylesheets = allowsStylesheets
        // Disk reads (possibly a slow network volume) happen off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let data = Self.resource(at: path, root: root, allowsStylesheets: allowsStylesheets)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.stopped.remove(id) == nil else { return }
                guard let data else {
                    task.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    /// The bytes of an image inside `root`, or nil.
    static func resource(at path: String, root: URL, allowsStylesheets: Bool = false) -> Data? {
        let file = URL(fileURLWithPath: path)
        let real = FileOperations.realPath(file)
        guard FileOperations.isInside(real, FileOperations.realPath(root)),
              let type = UTType(filenameExtension: file.pathExtension),
              type.conforms(to: .image) || (allowsStylesheets && file.pathExtension.lowercased() == "css"),
              let size = (try? FileManager.default.attributesOfItem(atPath: real))?[.size] as? Int,
              size <= maxBytes
        else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: real))
    }
}

enum HTMLPreview {
    /// Local preview has the same passive behavior as Markdown. In particular,
    /// scripts, frames and network resources in agent output cannot navigate
    /// the app or launch anything; only user-activated links leave the view.
    static func document(_ source: String) -> String {
        """
        <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src agentpad-doc: data:; style-src agentpad-doc: 'unsafe-inline'; font-src data:; form-action 'none'; base-uri 'none'">
        \(source)
        """
    }
}
