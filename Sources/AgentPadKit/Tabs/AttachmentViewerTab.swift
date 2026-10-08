import AppKit
import GRDB
import SwiftUI

@MainActor @Observable
final class AttachmentViewerModel {
    let key: ChatOrgKey
    let channel: String
    let messageID: String
    let attachmentID: String
    let tabs: CompositionTabs
    private weak var state: TabState?
    private var loaded: ChatAttachmentManager.Preview?
    private var ticket = UUID()
    var loading = false
    var problem: String?
    init(state: TabState, tabs: CompositionTabs) {
        guard case .viewer(let key, let channel, let message, let file) = state.route else { preconditionFailure("Viewer route required") }
        self.key = key.chatKey; self.channel = channel; messageID = message; attachmentID = file
        self.state = state; self.tabs = tabs
    }
    var manager: ChatAttachmentManager? { tabs.chat.attachments(key) }
    var message: ChatMessage? {
        guard state?.isClosed == false, let manager else { return nil }
        _ = manager.revision
        return try? manager.store.queue.read {
            try Row.fetchOne($0, sql: "SELECT * FROM messages WHERE message_id = ? AND channel_id = ?", arguments: [messageID, channel]).map(ChatMessage.init(row:))
        }
    }
    var file: ChatAttachment? { message?.attachments.first { $0.id == attachmentID } }
    var stamp: ChatAttachmentManager.Stamp? {
        guard let message, let file else { return nil }
        return manager?.stamp(channel: channel, message: message, file: file)
    }
    var preview: ChatAttachmentManager.Preview? {
        guard state?.isClosed == false, let loaded, manager?.current(loaded.stamp) == true, stamp == loaded.stamp else { return nil }
        return loaded
    }
    var zoom: Double {
        get { state?.navigation.zoom ?? 1 }
        set { state?.navigation.zoom = newValue; state?.changed() }
    }
    func load() async {
        if preview != nil { return }
        let id = UUID(); ticket = id; loaded = nil; problem = nil
        guard let manager, let message, let file, file.isImage, let capture = stamp else { loading = false; return }
        loading = true
        defer { if ticket == id { loading = false } }
        do {
            let bytes = try await manager.load(message, file: file, preview: false)
            guard !Task.isCancelled, ticket == id, stamp == capture, manager.current(capture), NSImage(data: bytes) != nil else { return }
            loaded = .init(stamp: capture, data: bytes)
        } catch { if ticket == id { problem = ChatAttachments.reason(error) } }
    }
    func invalidate() { ticket = UUID(); loaded = nil; loading = false }
    func save() async {
        guard let state, let owner = tabs.owner(state), let window = owner.session.engine.view.window,
              let manager, let message, let file, let capture = stamp else { return }
        let revision = state.revision
        let panel = NSSavePanel(); panel.nameFieldStringValue = file.name
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url,
              !state.isClosed, state.revision == revision, tabs.owner(state)?.store === owner.store, stamp == capture else { return }
        do {
            let bytes = try await manager.load(message, file: file, preview: false)
            guard !state.isClosed, state.revision == revision, tabs.owner(state)?.store === owner.store, stamp == capture else { return }
            try bytes.write(to: url, options: .atomic)
        } catch { problem = ChatAttachments.reason(error) }
    }
}

struct AttachmentViewerTab: View {
    @Bindable var model: AttachmentViewerModel
    var body: some View {
        VStack(spacing: 12) {
            if let preview = model.preview, let image = NSImage(data: preview.data) {
                HStack {
                    Text(preview.stamp.file?.name ?? "Image").font(.headline).lineLimit(1)
                    Spacer()
                    Slider(value: $model.zoom, in: 0.25...3).frame(maxWidth: 140).accessibilityLabel("Zoom")
                    Text("\(Int(model.zoom * 100))%")
                    Button("Save…") { Task { await model.save() } }
                }.padding(12)
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: min(680, image.size.width) * model.zoom)
                        .padding(16).accessibilityLabel(preview.stamp.file?.name ?? "Image")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.loading { ProgressView("Loading image…") }
            else {
                Text(model.problem ?? "Connect and check access to this attachment.").foregroundStyle(.secondary)
                if model.stamp != nil { Button("Reload") { Task { await model.load() } } }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: model.stamp) { await model.load() }
    }
}
