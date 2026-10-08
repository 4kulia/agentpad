import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor enum ChatAttachmentPaste {
    static func accepts(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil
    }
    /// Finder supplies image icons alongside file URLs. File URLs always win,
    /// and one handled paste never reaches NSTextView's ordinary text insertion.
    static func take(_ pasteboard: NSPasteboard, manager: ChatAttachmentManager, channel: String, root: String?,
                     completion: @escaping @MainActor (Error?) -> Void = { _ in }) throws -> Bool {
        if pasteboard.availableType(from: [.fileURL]) != nil {
            guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { throw ChatAttachmentError.source }
            try manager.importFiles(urls.map(ChatAttachmentWorker.Input.file), channel: channel, root: root, completion: completion); return true
        }
        guard let source = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return false }
        try manager.importFiles([.clipboard(source)], channel: channel, root: root, completion: completion)
        return true
    }
}

struct ChatAttachmentDraftStrip: View {
    let manager: ChatAttachmentManager
    let channel: String
    let root: String?
    var body: some View {
        VStack(spacing: 6) {
            if manager.isImporting(channel: channel, root: root) {
                HStack { ProgressView().controlSize(.small); Text("Preparing files…").font(Theme.display(11)); Spacer() }.padding(7)
            }
            ForEach(manager.files(channel: channel, root: root)) { draft in
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
                            if manager.canRetry(draft) { Button("Retry") { manager.retry(draft) }.buttonStyle(.link) }
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
        }.padding(.horizontal, 8).padding(.top, manager.files(channel: channel, root: root).isEmpty ? 0 : 8)
    }
    private func status(_ draft: ChatAttachmentDraft) -> String {
        if draft.state == .failed { return "Not sent" }
        if let reason = manager.pauseReason { return reason }
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
        if !message.deleted, manager.stamp(channel: message.channelId) != nil {
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
    let manager: ChatAttachmentManager
    let message: ChatMessage
    let file: ChatAttachment
    let width: CGFloat
    let height: CGFloat
    @State private var problem: String?
    @State private var busy = false
    @State private var retry = 0
    @State private var opening = false
    private struct PreviewTask: Hashable {
        var stamp: ChatAttachmentManager.Stamp?
        var retry: Int
    }
    private var available: Bool { manager.stamp(channel: message.channelId, message: message, file: file) != nil }
    private var imageHeight: CGFloat {
        guard let w = file.width, let h = file.height, w > 0, h > 0 else { return height }
        return max(44, min(height, width * CGFloat(h) / CGFloat(w)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if file.isImage {
                Button {
                    busy = true; problem = nil
                    Task {
                        do { try await manager.open(message, file: file); opening = manager.viewer?.id == file.id }
                        catch { problem = available ? ChatAttachments.reason(error) : "File unavailable." }
                        busy = false
                    }
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
        .accessibilityElement(children: .contain).accessibilityLabel("\(file.mime), \(file.name), \(file.sizeText)")
        .task(id: PreviewTask(stamp: manager.stamp(channel: message.channelId, message: message, file: file), retry: retry)) {
            guard file.isImage, file.hasPreview, available, manager.image(message, file: file) == nil else { return }
            problem = nil
            do { _ = try await manager.load(message, file: file, preview: true) }
            catch { if !Task.isCancelled { problem = available ? "Preview failed to load." : "File unavailable." } }
        }
        .sheet(isPresented: Binding(get: { opening && manager.viewer?.id == file.id && available }, set: { opening = $0; if !$0 { manager.closeViewer() } })) {
            ChatAttachmentViewer(manager: manager, message: message, file: file)
        }
    }
    private func save() {
        busy = true; problem = nil
        Task { do { try await manager.save(message, file: file) } catch { problem = ChatAttachments.reason(error) }; busy = false }
    }
}

struct ChatAttachmentViewer: View {
    let manager: ChatAttachmentManager
    let message: ChatMessage
    let file: ChatAttachment
    @State private var zoom: Double = 1
    @State private var problem: String?
    var body: some View {
        if let viewer = manager.viewer, manager.current(viewer.stamp), let image = NSImage(data: viewer.data) {
            VStack(spacing: 0) {
                HStack {
                    Text(file.name).font(.headline).lineLimit(1)
                    Spacer()
                    Slider(value: $zoom, in: 0.25...3).frame(width: 120).accessibilityLabel("Zoom")
                    Text("\(Int(zoom * 100))%").monospacedDigit().frame(width: 45)
                    Button("Save…") { Task { do { try await manager.save(message, file: file) } catch { problem = ChatAttachments.reason(error) } } }
                    Button("Close") { manager.closeViewer() }.keyboardShortcut(.cancelAction)
                }.padding(14)
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: min(680, image.size.width) * zoom)
                        .padding(16).accessibilityLabel(file.name)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let problem { Text(problem).font(.caption).padding(8) }
            }.frame(width: 760, height: 570).background(ChatAppearance.surface)
        }
    }
}
