import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor enum ChatAttachmentPaste {
    // Prefer the GIF over a provider's still PNG/TIFF representation so an
    // unsupported animation produces an error instead of silently losing frames.
    static let imageTypes: [NSPasteboard.PasteboardType] = [.init(UTType.gif.identifier), .png, .init(UTType.jpeg.identifier), .tiff,
        .init(UTType.heic.identifier), .init(UTType.heif.identifier)]
    static let types: [NSPasteboard.PasteboardType] = [.fileURL] + imageTypes
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    static func accepts(_ pasteboard: NSPasteboard, fromDrop: Bool = false) -> Bool {
        pasteboard.availableType(from: fromDrop ? types : [.fileURL] + imageTypes) != nil
    }
    /// Finder supplies image icons alongside file URLs. File URLs always win,
    /// and one handled paste never reaches NSTextView's ordinary text insertion.
    static func take(_ pasteboard: NSPasteboard, manager: ChatAttachmentManager, channel: String, root: String?, fromDrop: Bool = false,
                     completion: @escaping @MainActor (Error?) -> Void = { _ in }) throws -> Bool {
        try take(pasteboard, manager: manager, owner: .channel(channel), root: root, fromDrop: fromDrop, completion: completion)
    }
    static func takePromises(_ receivers: [NSFilePromiseReceiver], manager: ChatAttachmentManager, channel: String, root: String?,
                             completion: @escaping @MainActor (Error?) -> Void = { _ in }) throws {
        try takePromises(receivers, manager: manager, owner: .channel(channel), root: root, completion: completion)
    }
    static func take(_ pasteboard: NSPasteboard, manager: ChatAttachmentManager, owner: ChatAttachmentOwner, root: String?, fromDrop: Bool = false,
                     completion: @escaping @MainActor (Error?) -> Void = { _ in }) throws -> Bool {
        if pasteboard.availableType(from: [.fileURL]) != nil {
            guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { throw ChatAttachmentError.source }
            try manager.importFiles(urls.map(ChatAttachmentWorker.Input.file), owner: owner, root: root, completion: completion); return true
        }
        if fromDrop, let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            try takePromises(receivers, manager: manager, owner: owner, root: root, completion: completion)
            return true
        }
        guard let source = imageTypes.lazy.compactMap({ pasteboard.data(forType: $0) }).first else { return false }
        try manager.importFiles([.clipboard(source)], owner: owner, root: root, completion: completion)
        return true
    }
    static func takePromises(_ receivers: [NSFilePromiseReceiver], manager: ChatAttachmentManager, owner: ChatAttachmentOwner, root: String?,
                             completion: @escaping @MainActor (Error?) -> Void = { _ in }) throws {
        let promises = ChatAttachmentFilePromises(receivers)
        try manager.importFiles(count: receivers.reduce(0) { $0 + max(1, $1.fileTypes.count) }, owner: owner, root: root,
            start: { try promises.start() }, load: { try await promises.receive() }, cleanup: { promises.remove() }, completion: completion)
    }
}

/// Dragging a screenshot thumbnail can promise a file instead of a file URL.
/// Keep receipt inside the manager's import lifetime, so Send, revocation and
/// quotas behave exactly like a file that already exists on disk.
@MainActor private final class ChatAttachmentFilePromises {
    let receivers: [NSFilePromiseReceiver]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentpad-paste-" + UUID().uuidString, isDirectory: true)
    private var remaining = 0
    private var files: AsyncThrowingStream<URL, Error>?
    init(_ receivers: [NSFilePromiseReceiver]) { self.receivers = receivers }
    func start() throws {
        try ChatAttachmentStorage.secureDirectory(directory)
        // AppKit requires this call synchronously inside performDragOperation;
        // neither a clipboard paste nor a later Task may call in a file promise.
        files = AsyncThrowingStream<URL, Error> { continuation in
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: .main) { [self] url, error in
                    MainActor.assumeIsolated {
                        if let error { continuation.finish(throwing: error); return }
                        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
                            continuation.finish(throwing: ChatAttachmentError.source); return
                        }
                        continuation.yield(url)
                        remaining -= 1
                        if remaining == 0 { continuation.finish() }
                    }
                }
                // AppKit resolves names synchronously when accepting the promise;
                // legacy providers may promise several files in a single item.
                remaining += max(1, receiver.fileNames.count)
            }
        }
    }
    func receive() async throws -> [ChatAttachmentWorker.Input] {
        guard let files else { throw ChatAttachmentError.source }
        var inputs: [ChatAttachmentWorker.Input] = []
        for try await file in files { inputs.append(.file(file)) }
        try Task.checkCancellation()
        return inputs
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

struct ChatAttachmentDraftStrip: View {
    let manager: ChatAttachmentManager
    let owner: ChatAttachmentOwner
    let root: String?
    var allowsRetry = true
    init(manager: ChatAttachmentManager, owner: ChatAttachmentOwner, root: String?, allowsRetry: Bool = true) {
        self.manager = manager; self.owner = owner; self.root = root; self.allowsRetry = allowsRetry
    }
    init(manager: ChatAttachmentManager, channel: String, root: String?) { self.init(manager: manager, owner: .channel(channel), root: root) }
    var body: some View {
        VStack(spacing: 6) {
            if manager.isImporting(owner: owner, root: root) {
                HStack { ProgressView().controlSize(.small); Text("Preparing files…").font(Theme.display(11)); Spacer() }.padding(7)
            }
            ForEach(manager.files(owner: owner, root: root)) { draft in
                HStack(spacing: 9) {
                    if let image = manager.draftImage(draft) {
                        Image(decorative: image, scale: 2).resizable().scaledToFit().frame(width: 42, height: 38).clipShape(RoundedRectangle(cornerRadius: 4))
                    } else { Image(systemName: "doc").font(.system(size: 22)).frame(width: 42, height: 38).foregroundStyle(ChatAppearance.secondary) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(draft.file.name).font(Theme.display(11, weight: .medium)).lineLimit(1)
                        HStack(spacing: 5) {
                            Text(draft.file.sizeText)
                            Text("·")
                            Text(status(draft))
                            if allowsRetry && manager.canRetry(draft) { Button("Retry") { manager.retry(draft) }.buttonStyle(.link) }
                        }.font(Theme.display(10)).foregroundStyle(draft.state == .failed ? ChatAppearance.failure : ChatAppearance.secondary)
                        if draft.state == .uploading { ProgressView(value: draft.progress).progressViewStyle(.linear).frame(maxWidth: 230) }
                        if let problem = draft.problem { Text(problem).font(Theme.display(10)).foregroundStyle(ChatAppearance.failure) }
                    }
                    Spacer(minLength: 4)
                    Button("Delete") { manager.remove(draft) }
                        .buttonStyle(.link).help("Delete saved attachment").accessibilityLabel("Delete \(draft.file.name)").chatFocusRing()
                }.padding(7).background(Theme.chromeHover, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityElement(children: .contain).accessibilityLabel("\(draft.file.mime), \(draft.file.name), \(draft.file.sizeText), \(status(draft))")
            }
        }.padding(.horizontal, 8).padding(.top, manager.files(owner: owner, root: root).isEmpty ? 0 : 8)
    }
    private func status(_ draft: ChatAttachmentDraft) -> String {
        if draft.state == .failed { return "Not sent" }
        if let reason = manager.pauseReason(owner: owner) { return reason }
        return switch draft.state {
        case .waiting: "Waiting to upload"
        case .uploading: "Uploading · \(Int(draft.progress * 100))%"
        case .checking: "Verifying format…"
        case .ready: "Ready"
        case .failed: "Not sent"
        }
    }
}

struct ChatMessageAttachments: View {
    let manager: ChatAttachmentManager
    let message: ChatMessage
    var inThread = false
    var body: some View {
        if !message.deleted, manager.stamp(owner: message.attachmentOwner) != nil {
            VStack(alignment: .leading, spacing: 8) {
                let images = message.attachments.filter(\.isImage)
                if images.count > 1 {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: inThread ? 110 : 150))], alignment: .leading, spacing: 8) {
                        ForEach(images) { file in ChatAttachmentCard(manager: manager, message: message, file: file, width: inThread ? 132 : 172, height: inThread ? 130 : 180) }
                    }.frame(maxWidth: inThread ? 280 : 360)
                } else if let file = images.first {
                    ChatAttachmentCard(manager: manager, message: message, file: file, width: inThread ? 280 : 360, height: inThread ? 180 : 240)
                }
                ForEach(message.attachments.filter { !$0.isImage }) { file in
                    ChatAttachmentCard(manager: manager, message: message, file: file, width: inThread ? 280 : 360, height: 52)
                }
            }.padding(.top, 5)
        }
    }
}

struct ChatAttachmentCard: View {
    @State private var host = ChatSidebarWindowReference()
    let manager: ChatAttachmentManager
    let message: ChatMessage
    let file: ChatAttachment
    let width: CGFloat
    let height: CGFloat
    @State private var problem: String?
    @State private var busy = false
    @State private var retry = 0
    private struct PreviewTask: Hashable {
        var stamp: ChatAttachmentManager.Stamp?
        var retry: Int
    }
    private var available: Bool { manager.stamp(owner: message.attachmentOwner, message: message, file: file) != nil }
    private var imageHeight: CGFloat {
        guard let w = file.width, let h = file.height, w > 0, h > 0 else { return height }
        return max(44, min(height, width * CGFloat(h) / CGFloat(w)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if file.isImage {
                Button {
                    CompositionTabs.shared.viewer(key: manager.key, message: message, file: file)
                } label: {
                    Group {
                        if let image = manager.image(message, file: file) { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                        else if problem != nil { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(ChatAppearance.secondary) }
                        else { ProgressView().controlSize(.small) }
                    }.frame(maxWidth: width).frame(height: imageHeight)
                        .background(Theme.chromeHover, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!available || busy).help("Open image").chatFocusRing()
                Text(file.name).font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary).lineLimit(1)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text").font(.system(size: 23)).foregroundStyle(ChatAppearance.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.name).font(Theme.display(12, weight: .medium)).lineLimit(1)
                        Text("\(file.mime) · \(file.sizeText)").font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
                    }
                    Spacer(minLength: 4)
                    if busy { ProgressView().controlSize(.mini) }
                    else { Button { save() } label: { Image(systemName: "arrow.down.to.line").frame(width: 28, height: 28) }
                        .buttonStyle(.plain).help("Save…").accessibilityLabel("Save \(file.name)").chatFocusRing().disabled(!available) }
                }.padding(10).frame(maxWidth: width).background(Theme.chromeHover, in: RoundedRectangle(cornerRadius: 7))
            }
            if let problem {
                HStack { Text(problem); if available { Button("Retry") { self.problem = nil; if file.isImage { retry += 1 } else { save() } }.buttonStyle(.link) } }
                    .font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
            }
        }
        .background(ChatSidebarWindowReader(reference: host))
        .accessibilityElement(children: .contain).accessibilityLabel("\(file.mime), \(file.name), \(file.sizeText)")
        .task(id: PreviewTask(stamp: manager.stamp(owner: message.attachmentOwner, message: message, file: file), retry: retry)) {
            guard file.isImage, file.hasPreview, available, manager.image(message, file: file) == nil else { return }
            problem = nil
            do { _ = try await manager.load(message, file: file, preview: true) }
            catch { if !Task.isCancelled { problem = available ? "Preview failed to load." : "File unavailable." } }
        }

    }
    private func save() {
        guard let window = host.window, let anchor = host.view,
              let session = TabRouter.shared.stores().flatMap(\.allSessions).first(where: { anchor.isDescendant(of: $0.engine.view) }),
              let owner = TabRouter.shared.owner(of: session.id) else { return }
        busy = true; problem = nil
        Task {
            do { try await manager.save(message, file: file, window: window, stillValid: {
                host.window === window && TabRouter.shared.owner(of: session.id)?.store === owner.store
                    && anchor.isDescendant(of: session.engine.view)
            }) }
            catch { problem = ChatAttachments.reason(error) }
            busy = false
        }
    }
}
