import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// The file preview under the terminal: which file is open in which window,
/// what kind of content it is, and live reload when it changes on disk.
@MainActor
@Observable
final class FilePreviewModel {
    enum Content: Equatable, Sendable {
        /// UTF-8 text. `truncated` when only the first `textByteLimit` were read.
        /// Spans are computed during loading, off the main thread.
        case text(String, language: SyntaxLanguage, truncated: Bool, spans: [SyntaxHighlighter.Span])
        /// Source and its rendered HTML body page, both built off the main thread.
        case markdown(String, html: String)
        /// Images, PDF, documents, media — anything Quick Look renders.
        case quickLook
        case directory
        case unreadable(String)
    }

    nonisolated static let textByteLimit = 5 * 1024 * 1024

    private(set) var url: URL?
    private(set) var content: Content?
    /// Markdown: show the source instead of the rendered page.
    var showsMarkdownSource = false
    /// Bumped on every reload so Quick Look and the web view refresh.
    private(set) var revision = 0
    /// Panel height as a fraction of the main area.
    var heightFraction: CGFloat = 0.45

    private var watcher: DispatchSourceFileSystemObject?
    private var reloadTask: Task<Void, Never>?

    var isOpen: Bool { url != nil }

    // One model per window store, created on first use. Weak keys: a closed
    // window's entry is purged (and its watcher closed) on the next lookup,
    // and a recycled ObjectIdentifier can't inherit a dead window's state.
    private struct Entry { weak var store: WorkspaceStore?; let model: FilePreviewModel }
    private static var models: [ObjectIdentifier: Entry] = [:]

    static func `for`(_ store: WorkspaceStore) -> FilePreviewModel {
        for (key, entry) in models where entry.store == nil {
            entry.model.close()
            models[key] = nil
        }
        let key = ObjectIdentifier(store)
        if let entry = models[key], entry.store === store { return entry.model }
        let model = FilePreviewModel()
        models[key] = Entry(store: store, model: model)
        return model
    }

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        guard url != self.url else { return }
        self.url = url
        showsMarkdownSource = false
        reload()
        watch(url)
    }

    func close() {
        url = nil
        content = nil
        pendingReload?.cancel()
        needsReattach = false
        stopWatching()
    }

    func reload() {
        guard let url else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { Self.load(url) }.value
            guard !Task.isCancelled, let self, self.url == url else { return }
            self.content = loaded
            self.revision += 1
        }
    }

    // MARK: Loading

    enum Kind: Equatable { case markdown, text, binary, unknown }

    nonisolated static func kind(of url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "mdown", "mkd"].contains(ext) { return .markdown }
        if SyntaxLanguage.knownTextExtensions.contains(ext) { return .text }
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), type.isDeclared {
            if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return .text }
            return .binary
        }
        return .unknown
    }

    nonisolated static func load(_ url: URL) -> Content {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return .unreadable("The file no longer exists.")
        }
        if isDir.boolValue { return .directory }
        let kind = kind(of: url)
        // Known binary types go to Quick Look. Unknown ones (Makefile,
        // LICENSE, .env…) are sniffed: text if the head is UTF-8 without NULs.
        switch kind {
        case .binary: return .quickLook
        case .unknown where !sniffText(url): return .quickLook
        default: break
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .unreadable("The file can't be read.")
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: textByteLimit + 1)) ?? Data()
        let truncated = data.count > textByteLimit
        let slice = truncated ? data.prefix(textByteLimit) : data
        // A cut can split a multi-byte character; decoding leniently keeps the rest.
        let text = String(decoding: slice, as: UTF8.self)
        if kind == .markdown && !truncated {
            return .markdown(text, html: MarkdownRenderer.page(body: MarkdownRenderer.html(text)))
        }
        let language = SyntaxLanguage(fileName: url.lastPathComponent)
        return .text(text, language: language, truncated: truncated, spans: SyntaxHighlighter.spans(in: text, language: language))
    }

    nonisolated static func sniffText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8192) else { return false }
        if head.isEmpty { return true }
        if head.contains(0) { return false }
        if String(data: head, encoding: .utf8) != nil { return true }
        // A full sample may end mid-character; allow that, but nothing else.
        guard head.count == 8192 else { return false }
        return (1...3).contains { String(data: head.dropLast($0), encoding: .utf8) != nil }
    }

    // MARK: Watching

    private var reattachTask: Task<Void, Never>?

    private func watch(_ url: URL) {
        stopWatching()
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            retryWatch(url)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            MainActor.assumeIsolated {
                // Editors and agents often save by replacing the file; the
                // old descriptor then points at nothing, so re-attach.
                if events.contains(.delete) || events.contains(.rename) {
                    self.scheduleReload(reattach: true)
                } else {
                    self.scheduleReload(reattach: false)
                }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        reattachTask?.cancel()
        reattachTask = nil
        watcher?.cancel()
        watcher = nil
    }

    /// The file is gone for now (deleted, or mid-replace): poll for it for a
    /// while, then reload and watch again once it's back.
    private func retryWatch(_ url: URL) {
        reattachTask?.cancel()
        reattachTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.url == url else { return }
                if FileManager.default.fileExists(atPath: url.path) {
                    self.reattachTask = nil
                    self.watch(url)
                    self.reload()
                    return
                }
            }
        }
    }

    private var pendingReload: Task<Void, Never>?
    /// Sticky across a coalesced burst: one rename in the burst is enough.
    private var needsReattach = false

    private func scheduleReload(reattach: Bool) {
        needsReattach = needsReattach || reattach
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            // Coalesce a burst of writes into one reload.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, let url = self.url else { return }
            if self.needsReattach {
                self.needsReattach = false
                self.watch(url)
            }
            self.reload()
        }
    }
}
