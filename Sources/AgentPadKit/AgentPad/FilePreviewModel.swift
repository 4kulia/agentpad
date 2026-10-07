import AppKit
import CryptoKit
import Foundation
import ImageIO
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
        case html(String)
        /// An eagerly decoded bitmap; displaying it needs no file IO or decoding.
        case image(DecodedImage)
        /// PDF, documents, media and image formats ImageIO can't render.
        case quickLook
        case directory
        case unreadable(String)
    }

    struct DecodedImage: Equatable, Sendable {
        let cgImage: CGImage

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.cgImage === rhs.cgImage
        }
    }

    nonisolated static let textByteLimit = 5 * 1024 * 1024

    private(set) var url: URL?
    private(set) var content: Content?
    /// Markdown: show the source instead of the rendered page.
    var showsMarkdownSource = false
    /// A fresh identity for every click, including the same file/location.
    private(set) var sourceLocation: FilePreviewLocation?
    /// Bumped only when new content is ready to display.
    private(set) var revision = 0
    /// Panel height as a fraction of the main area.
    var heightFraction: CGFloat = 0.45

    private var watcher: DispatchSourceFileSystemObject?
    private var reloadTask: Task<Void, Never>?
    enum ReloadReason { case attributes, contents }
    private var reloadRequested: ReloadReason?
    private var loadedVersion: FileVersion?
    private var imageDigest: SHA256.Digest?
    // Allows deterministic IO-race tests without timing a large file's decode.
    private let didRead: @Sendable (URL) -> Void

    init(didRead: @escaping @Sendable (URL) -> Void = { _ in }) {
        self.didRead = didRead
    }

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

    func open(_ url: URL, line: Int? = nil, column: Int? = nil) {
        let url = url.standardizedFileURL
        sourceLocation = line.map { FilePreviewLocation(line: $0, column: column) }
        showsMarkdownSource = line != nil
        guard url != self.url else { return }
        reloadTask?.cancel()
        reloadTask = nil
        reloadRequested = nil
        pendingReload?.cancel()
        pendingReload = nil
        reloadDeadline = nil
        pendingReason = .attributes
        needsReattach = false
        loadedVersion = nil
        imageDigest = nil
        self.url = url
        content = nil
        watch(url)
        reload()
    }

    func close() {
        url = nil
        content = nil
        sourceLocation = nil
        reloadTask?.cancel()
        reloadTask = nil
        reloadRequested = nil
        pendingReload?.cancel()
        pendingReload = nil
        reloadDeadline = nil
        pendingReason = .attributes
        needsReattach = false
        loadedVersion = nil
        imageDigest = nil
        stopWatching()
    }

    func reload(reason: ReloadReason = .contents) {
        guard let url else { return }
        // A burst during a slow decode needs one follow-up check, not more
        // concurrent decoders or cancellation/restart starvation.
        guard reloadTask == nil else {
            if reloadRequested != .contents { reloadRequested = reason }
            return
        }
        let previousVersion = loadedVersion
        let previousDigest = imageDigest
        let hasContent = content != nil
        let didRead = didRead
        reloadTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { () -> ReloadResult in
                let version = FileVersion.read(url)
                // Quick Look itself can generate .attrib events. Only these
                // may skip reading an unchanged stamp; writes still hash bytes.
                guard !Task.isCancelled else { return .unchanged }
                if reason == .attributes, hasContent, version == previousVersion { return .unchanged }
                let loaded = Self.read(url, previousImageDigest: previousDigest)
                didRead(url)
                guard !Task.isCancelled else { return .unchanged }
                // Don't publish bytes from an in-progress write or cache the
                // new file's stamp alongside an image read from its predecessor.
                let after = FileVersion.read(url)
                if after != version {
                    // Text is a bounded snapshot. Appending while it is read
                    // must not keep the first preview on a spinner forever.
                    guard loaded.isTextSnapshot, let version, let after,
                          version.device == after.device, version.inode == after.inode,
                          after.size >= version.size else { return .retry }
                    return .loaded(nil, loaded, retry: true)
                }
                return .loaded(version, loaded, retry: false)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, self.url == url else { return }
            self.reloadTask = nil
            defer {
                if let reason = self.reloadRequested {
                    self.reloadRequested = nil
                    self.reload(reason: reason)
                }
            }
            switch result {
            case .unchanged:
                break
            case .retry:
                self.scheduleReload(reattach: false, reason: .contents)
            case .loaded(let version, let loaded, let retry):
                defer { if retry { self.scheduleReload(reattach: false, reason: .contents) } }
                self.loadedVersion = version
                guard let content = loaded.content else { return } // identical image bytes
                if case .image = self.content {
                    // A truncate/write or delete/recreate save can temporarily
                    // be unreadable. Keep the last good frame until decoding succeeds.
                    switch content {
                    case .quickLook, .unreadable: return
                    default: break
                    }
                }
                self.imageDigest = loaded.imageDigest
                if content != self.content || content == .quickLook {
                    self.content = content
                    self.revision += 1
                }
            }
        }
    }

    // MARK: Loading

    /// Ignore access time, permissions and other metadata-only notifications.
    /// Inode/device also catch atomic replacements that preserve size and mtime.
    private struct FileVersion: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        nonisolated static func read(_ url: URL) -> Self? {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            return Self(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                        modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec)
        }
    }

    private struct LoadedContent: Sendable {
        /// Nil means the image's bytes match the already displayed image.
        let content: Content?
        let imageDigest: SHA256.Digest?

        var isTextSnapshot: Bool {
            switch content {
            case .text, .markdown, .html: true
            default: false
            }
        }

        nonisolated init(_ content: Content?, imageDigest: SHA256.Digest? = nil) {
            self.content = content
            self.imageDigest = imageDigest
        }
    }

    private enum ReloadResult: Sendable {
        case unchanged
        case retry
        case loaded(FileVersion?, LoadedContent, retry: Bool)
    }

    enum Kind: Equatable { case markdown, html, text, binary, unknown }

    nonisolated static func kind(of url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "mdown", "mkd"].contains(ext) { return .markdown }
        if ["html", "htm"].contains(ext) { return .html }
        if SyntaxLanguage.knownTextExtensions.contains(ext) { return .text }
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), type.isDeclared {
            if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return .text }
            return .binary
        }
        return .unknown
    }

    nonisolated static func load(_ url: URL) -> Content {
        // Without an earlier digest read() always returns content.
        read(url, previousImageDigest: nil).content ?? .quickLook
    }

    nonisolated private static func read(_ url: URL, previousImageDigest: SHA256.Digest?) -> LoadedContent {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return .init(.unreadable("File not found. It may have been moved or deleted. Check the path and the terminal's working folder."))
        }
        if isDir.boolValue { return .init(.directory) }
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
           let data = try? Data(contentsOf: url) {
            let digest = SHA256.hash(data: data)
            if digest == previousImageDigest { return .init(nil, imageDigest: digest) }
            if !Task.isCancelled, let image = decodeImage(data) {
                return .init(.image(image), imageDigest: digest)
            }
            // Preserve Quick Look support for vectors, animations and multi-page images.
            return .init(.quickLook, imageDigest: digest)
        }
        let kind = kind(of: url)
        // Known binary types go to Quick Look. Unknown ones (Makefile,
        // LICENSE, .env…) are sniffed: text if the head is UTF-8 without NULs.
        switch kind {
        case .binary: return .init(.quickLook)
        case .unknown where !sniffText(url): return .init(.quickLook)
        default: break
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .init(.unreadable("The file can't be read."))
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: textByteLimit + 1)) ?? Data()
        let truncated = data.count > textByteLimit
        let slice = truncated ? data.prefix(textByteLimit) : data
        // A cut can split a multi-byte character; decoding leniently keeps the rest.
        let text = String(decoding: slice, as: UTF8.self)
        if kind == .markdown && !truncated {
            return .init(.markdown(text, html: MarkdownRenderer.page(body: MarkdownRenderer.html(text))))
        }
        if kind == .html && !truncated { return .init(.html(text)) }
        let language = SyntaxLanguage(fileName: url.lastPathComponent)
        return .init(.text(text, language: language, truncated: truncated, spans: SyntaxHighlighter.spans(in: text, language: language)))
    }

    nonisolated private static func decodeImage(_ data: Data) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // Full resolution, including EXIF orientation. CacheImmediately forces
        // decoding here, in the detached loader, instead of the first UI draw.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return DecodedImage(cgImage: image)
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
            guard let self, self.watcher === source, self.url == url else { return }
            let events = source.data
            MainActor.assumeIsolated {
                self.fileDidChange(events)
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
    private var reloadDeadline: ContinuousClock.Instant?
    private var pendingReason: ReloadReason = .attributes
    /// Sticky across a coalesced burst: one rename in the burst is enough.
    private var needsReattach = false

    func fileDidChange(_ events: DispatchSource.FileSystemEvent) {
        // An .attrib coalesced with a write must never hide that write.
        let reattach = !events.intersection([.delete, .rename]).isEmpty
        scheduleReload(reattach: reattach, reason: events == .attrib ? .attributes : .contents)
    }

    private func scheduleReload(reattach: Bool, reason: ReloadReason) {
        needsReattach = needsReattach || reattach
        if reason == .contents { pendingReason = .contents }
        let deadline = reloadDeadline ?? (ContinuousClock.now + .seconds(1))
        reloadDeadline = deadline
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            // Debounce short bursts, but never postpone a growing log forever.
            let delay = max(.zero, min(.milliseconds(150), ContinuousClock.now.duration(to: deadline)))
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let url = self.url else { return }
            self.pendingReload = nil
            self.reloadDeadline = nil
            let reason = self.pendingReason
            self.pendingReason = .attributes
            if self.needsReattach {
                self.needsReattach = false
                self.watch(url)
            }
            self.reload(reason: reason)
        }
    }
}
