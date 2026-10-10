import AppKit
import SwiftUI

struct ChatDMTab: View {
    @Bindable var state: TabState
    let ref: ChatDMRef
    var service: ChatService = .shared
    private var available: Bool { ref.key.map { service.dmAllowed($0, ref.dm) } == true && !state.isClosed }
    var body: some View {
        Group {
            if available, let model = state.dmModel, let card = model.card { ChatDMView(model: model, card: card) }
            else {
                VStack(spacing: 12) {
                    Image(systemName: "lock").font(.title)
                    Text(status).foregroundStyle(ChatAppearance.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
            .onChange(of: available, initial: true) { _, available in
                if available, let key = ref.key, state.dmModel == nil {
                    let model = ChatDMModel(key: key, dm: ref.dm, state: state, service: service)
                    model.tabID = SupportTabs.shared.owner(state)?.session.id
                    state.dmModel = model
                    if let target = state.dmSearchTarget { model.navigateToSearchMessage(target); state.dmSearchTarget = nil }
                    if let root = state.dmPendingThread { model.openThread(root); state.dmPendingThread = nil }
                    state.canShowConfirmation = { [weak model] in model?.readable == true }
                    _ = service.dmList(key)
                } else if !available { state.dmModel?.stop(); state.dmModel = nil; state.confirmation.invalidate() }
            }
            .environment(\.openURL, OpenURLAction { ChatMarkdownText.open($0) })
    }
    private var status: String {
        guard let key = ref.key, service.connection?.orgKey == key, service.state == .signedIn else { return "Not connected" }
        guard service.supports("chat.dm", key: key) else { return "Direct messages are not available on this server." }
        return service.dmAllowed(key) ? "No access" : "Checking access…"
    }
}

struct ChatDMView: View {
    let model: ChatDMModel
    let card: ChatDMCard
    private var members: [ChatOrgView.Member] {
        let me = (ChatOrgCurrent.shared.model?.key == model.key ? ChatOrgCurrent.shared.model?.members.first { $0.accountId == model.key.accountId } : nil)
            ?? .init(accountId: model.key.accountId, handle: "", name: "You", role: "member")
        return [me, .init(accountId: card.peer.accountId, handle: card.peer.handle, name: card.peer.name, role: "member")]
    }
    private var mentionable: [(account: String, handle: String)] { members.filter { !$0.handle.isEmpty }.map { ($0.accountId, $0.handle) } }
    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 784
            HSplitView {
                if !narrow || model.threadRoot == nil {
                    VStack(spacing: 0) {
                        header
                        if card.writable, model.service.socket?.state != .connected {
                            Text("Offline — messages will be sent when the connection returns.")
                                .font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary).padding(10)
                        }
                        if model.feed.messages.isEmpty {
                            VStack(spacing: 8) {
                                ContactAvatar(stableID: card.peer.accountId, name: card.peer.name, kind: .person, size: 48, remote: .account(card.peer.accountId, model.key))
                                Text(card.peer.name).font(Theme.display(19, weight: .semibold))
                                Text("Only the two of you can read this conversation. Organization admins and owners can't.")
                                    .font(Theme.display(12)).foregroundStyle(ChatAppearance.secondary).multilineTextAlignment(.center)
                            }.padding(24)
                        }
                        ChatTimelineView(model: model, root: nil, members: members, mentionable: mentionable,
                            me: model.key.accountId, archived: !card.writable, ownerModel: nil)
                        composer(root: nil)
                    }.frame(minWidth: narrow ? 0 : 410)
                }
                if let root = model.threadRoot {
                    VStack(spacing: 0) {
                        HStack {
                            if narrow { ChatIconButton(title: "Back to conversation", symbol: "chevron.left") { model.openThread(nil) } }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Thread").font(Theme.display(13, weight: .semibold))
                                Label("\(card.peer.name) and you", systemImage: "lock").font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
                            }
                            Spacer()
                            ChatIconButton(title: "Mark as read", symbol: "checkmark") { model.markConversationRead(root: root) }
                            ChatIconButton(title: "Close thread", symbol: "xmark") { model.openThread(nil) }
                        }.padding(16)
                        Divider()
                        ChatTimelineView(model: model, root: root, members: members, mentionable: mentionable,
                            me: model.key.accountId, archived: !card.writable, ownerModel: nil)
                        composer(root: root)
                    }.frame(minWidth: narrow ? 0 : 300, idealWidth: 344, maxWidth: narrow ? .infinity : 480)
                        .background(ChatThreadSplitPosition(enabled: !narrow))
                }
            }
        }
    }
    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ContactAvatar(stableID: card.peer.accountId, name: card.peer.name, kind: .person, size: 34, remote: .account(card.peer.accountId, model.key))
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.peer.name).font(Theme.display(15, weight: .semibold))
                    Label("Only the two of you", systemImage: "lock").font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary)
                }
                Spacer()
                ChatIconButton(title: "Mark as read", symbol: "checkmark") { model.markConversationRead(root: nil) }
                ChatIconButton(title: model.muted ? "Unmute direct message" : "Mute direct message", symbol: model.muted ? "bell.slash" : "bell") { model.setMuted(!model.muted) }
            }.padding(.horizontal, 24).padding(.vertical, 15)
            Divider()
        }
    }
    @ViewBuilder private func composer(root: String?) -> some View {
        if root == nil, let manager = model.attachmentManager {
            ForEach(model.orphanedFileDraftRoots, id: \.self) { savedRoot in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved reply draft — its thread is not loaded").font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
                    if let draft = model.draft(root: savedRoot), !draft.text.isEmpty { Text(draft.text).font(Theme.display(12)).textSelection(.enabled) }
                    ChatAttachmentDraftStrip(manager: manager, owner: .dm(model.ref.dm), root: savedRoot, allowsRetry: false)
                    Button("Delete draft") { model.deleteDraft(root: savedRoot) }.buttonStyle(.link)
                }.padding(12)
            }
        }
        if card.writable { ChatDMComposer(model: model, root: root, members: members, peer: card.peer.name) }
        else {
            VStack(alignment: .leading, spacing: 8) {
                Label(root == nil ? "\(card.peer.name) was removed from the organization" : "Read-only", systemImage: "lock").font(Theme.display(12, weight: .semibold))
                Text("The history remains available. New messages, edits and deletions are turned off.").font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary)
                let savedFiles = model.attachmentManager?.files(owner: .dm(model.ref.dm), root: root) ?? []
                if model.draft(root: root)?.text.isEmpty == false || !savedFiles.isEmpty {
                    Text("Your unsent draft — kept on this Mac only").font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
                    if let draft = model.draft(root: root), !draft.text.isEmpty { Text(draft.text).font(Theme.display(12)).textSelection(.enabled) }
                    if let manager = model.attachmentManager { ChatAttachmentDraftStrip(manager: manager, owner: .dm(model.ref.dm), root: root) }
                    HStack {
                        if model.draft(root: root)?.text.isEmpty == false {
                            Button("Copy") {
                                guard let current = model.draft(root: root), !current.text.isEmpty else { return }
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(current.text, forType: .string)
                            }
                        }
                        Button("Delete draft") { model.deleteDraft(root: root) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(ChatAppearance.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)).padding(16)
        }
    }
}

@MainActor
protocol ChatDMComposing: AnyObject {
    var key: ChatOrgKey { get }
    var writable: Bool { get }
    var problem: String? { get }
    var attachmentManager: ChatAttachmentManager? { get }
    var attachmentOwner: ChatAttachmentOwner? { get }
    func attachmentProblem(_ error: Error)
    func prepareAttachments() async throws -> ChatAttachmentOwner
    func draft(root: String?) -> ChatDMContent.Draft?
    @discardableResult func saveDraft(_ text: String, root: String?) -> String?
    func send(_ text: String, root: String?, members: [(account: String, handle: String)], version: String?) -> Bool
    func openThread(_ id: String?)
    func conversationMessages(root: String?) -> [ChatMessage]
    func canEdit(_ message: ChatMessage) -> Bool
    @discardableResult func beginEditing(_ message: ChatMessage, root: String?, recovering: Bool) -> Bool
}

extension ChatDMModel: ChatDMComposing {
    var attachmentManager: ChatAttachmentManager? { service.attachments(key) }
    var attachmentOwner: ChatAttachmentOwner? { .dm(ref.dm) }
    func prepareAttachments() async throws -> ChatAttachmentOwner { .dm(ref.dm) }
}

struct ChatDMComposer: View {
    let model: any ChatDMComposing
    let root: String?
    let members: [ChatOrgView.Member]
    let peer: String
    var isActive: () -> Bool = { true }
    @State private var text = ""
    @State private var version: String?
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var control = ChatEditorControl()
    @State private var height: CGFloat = 58
    @State private var candidateIndex = 0
    @State private var dismissed = false
    @State private var fileHint = false
    @State private var dropping = false
    @State private var choosingFiles = false
    private var attachments: ChatAttachmentManager? { model.attachmentManager }
    private var owner: ChatAttachmentOwner? { model.attachmentOwner }
    private var fileUI: Bool { owner != nil && attachments?.limits(for: owner ?? .dm("")) != nil }
    private var uploads: [ChatAttachmentDraft] { owner.map { attachments?.files(owner: $0, root: root) ?? [] } ?? [] }

    private var candidates: [ChatMentionCandidate] { members.filter { !$0.handle.isEmpty }.map { .init(id: $0.accountId, address: $0.handle, label: $0.name) } }
    private var token: (range: NSRange, query: String)? { ChatMentionCandidate.token(text, caret: selection.location) }
    private var matches: [ChatMentionCandidate] { dismissed ? [] : token.map { ChatMentionCandidate.filtered(candidates, query: $0.query) } ?? [] }
    private var mentionable: [(account: String, handle: String)] { members.map { ($0.accountId, $0.handle) } }
    private var canSend: Bool {
        isActive() && model.writable && version != nil && !choosingFiles
            && (owner.map { attachments?.isImporting(owner: $0, root: root) } ?? false) != true
            && (ChatChannelModel.textProblem(text) == nil || text.isEmpty && !uploads.isEmpty)
            && (uploads.isEmpty || fileUI) && uploads.allSatisfy { $0.state == .ready }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let problem = model.problem { Text(problem).font(Theme.display(11)).foregroundStyle(ChatAppearance.failure) }
            HStack {
                Text(dropping ? "Attach to: \(peer)" : (root == nil ? "Message to \(peer)" : "Reply to \(peer)"))
                Spacer()
                if !text.isEmpty || !uploads.isEmpty { Label("Draft", systemImage: "pencil") }
            }.font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
            ChatComposerBox(control: control, attachments: attachments, owner: owner, root: root, fileUI: fileUI,
                            mentionTitle: "Mention a person", canSend: canSend, chooseFiles: chooseFiles, send: send) {
                ChatMentionEditor(text: $text, selection: $selection, candidates: candidates, autofocus: root != nil, control: control,
                    heightChanged: { height = $0 }, placeholder: root == nil ? "Message \(peer)" : "Reply…", accessibilityName: root == nil ? "Direct message" : "Reply",
                    suggestions: .init(sections: ChatMentionSection.grouped(matches), selected: min(candidateIndex, max(0, matches.count - 1)), title: "Mention a person", choose: choose, key: model.key),
                    attachments: { attach($0) }, dropAttachments: { attach($0, fromDrop: true) }, dropTarget: { dropping = $0 }, key: key)
                    .frame(height: height)
            }
            if fileUI, let limits = attachments?.limits {
                Text("Up to \(limits.messageFiles) files · \(ByteCountFormatter.string(fromByteCount: Int64(limits.fileBytes), countStyle: .file)) each · \(ByteCountFormatter.string(fromByteCount: Int64(limits.messageBytes), countStyle: .file)) total")
                    .font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary)
            }
            if fileHint {
                HStack {
                    Text("Attachments are not available in this conversation on this server.")
                    Button("Dismiss") { fileHint = false }.buttonStyle(.link)
                }.font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
            }
            if root == nil {
                HStack {
                    Label("Only you and \(peer)", systemImage: "lock")
                    Spacer()
                    Text(attachments?.limits(for: .dm("")) == nil ? "Enter — send · ⇧Enter — new line" : "⌘↩ Send · Return for a new line")
                }.font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary)
            }
        }.padding(root == nil ? 20 : 14)
            .onAppear { loadDraft() }
            .onChange(of: root) { _, _ in loadDraft() }
            .onChange(of: model.draft(root: root)) { _, draft in
                if draft?.version != version { text = draft?.text ?? ""; version = draft?.version }
            }
            .onChange(of: text) { _, value in
                guard isActive() else { return }
                dismissed = false; candidateIndex = 0
                if model.draft(root: root)?.text != value { version = model.saveDraft(value, root: root) }
            }
    }
    private func loadDraft() {
        guard isActive() else { return }
        let draft = model.draft(root: root); text = draft?.text ?? ""
        version = draft?.version ?? model.saveDraft(text, root: root)
    }
    private func attach(_ pasteboard: NSPasteboard, fromDrop: Bool = false) -> Bool {
        guard isActive(), ChatAttachmentPaste.accepts(pasteboard, fromDrop: fromDrop) else { return false }
        guard fileUI, let attachments else { fileHint = true; return true }
        guard let owner else {
            // Establish the private pair before accepting bytes. The peer model
            // normally resolves this while the new conversation tab opens.
            Task { do { _ = try await model.prepareAttachments() } catch { model.attachmentProblem(error) } }
            model.attachmentProblem(ChatError.storage("Opening the conversation. Paste or drop the files again when it is ready."))
            return true
        }
        do {
            return try ChatAttachmentPaste.take(pasteboard, manager: attachments, owner: owner, root: root, fromDrop: fromDrop) { error in
                if let error { model.attachmentProblem(error) }
                version = model.draft(root: root)?.version
            }
        } catch { model.attachmentProblem(error); return true }
    }
    private func chooseFiles() {
        guard isActive(), let attachments, let window = control.view?.window else { return }
        choosingFiles = true
        Task {
            defer { choosingFiles = false }
            do {
                let owner = try await model.prepareAttachments()
                guard isActive(), model.writable else { return }
                ChatComposerFileSelection.choose(attachments: attachments, owner: owner, root: root, window: window,
                    valid: { isActive() && model.writable }) { error in
                        if let error { model.attachmentProblem(error) }
                        version = model.draft(root: root)?.version
                    }
            } catch { model.attachmentProblem(error) }
        }
    }
    private func choose(_ candidate: ChatMentionCandidate) {
        guard let token else { return }
        control.replace(token.range, with: "@\(candidate.address) "); dismissed = true
    }
    private func send() {
        guard canSend, model.send(text, root: root, members: mentionable, version: version) else { return }
        control.clearAfterSend(); text = ""; version = model.saveDraft("", root: root)
    }
    private func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        if attachments?.limits(for: .dm("")) == nil, (code == 36 || code == 76),
           modifiers.intersection([.shift, .option, .control]).isEmpty, matches.isEmpty { send(); return true }
        switch ChatComposerKey.action(code: code, modifiers: modifiers, hasCandidates: !matches.isEmpty, text: text, inThread: root != nil) {
        case .send: send(); return true
        case .previousCandidate: candidateIndex = max(0, candidateIndex - 1); return true
        case .nextCandidate: candidateIndex = min(matches.count - 1, candidateIndex + 1); return true
        case .chooseCandidate: if !matches.isEmpty { choose(matches[min(candidateIndex, matches.count - 1)]) }; return true
        case .dismissCandidates: dismissed = true; return true
        case .closeThread: model.openThread(nil); return true
        case .editLast:
            guard let message = model.conversationMessages(root: root).last(where: model.canEdit) else { return false }
            return model.beginEditing(message, root: root, recovering: false)
        case .native: return false
        }
    }
}
