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
                        if model.service.socket?.state != .connected {
                            Text("Offline — messages will be sent when the connection returns.")
                                .font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary).padding(10)
                        }
                        if model.feed.messages.isEmpty {
                            VStack(spacing: 8) {
                                ContactAvatar(stableID: card.peer.accountId, name: card.peer.name, kind: .person, size: 48)
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
                ContactAvatar(stableID: card.peer.accountId, name: card.peer.name, kind: .person, size: 34)
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
        if card.writable { ChatDMComposer(model: model, root: root, members: members, peer: card.peer.name) }
        else {
            VStack(alignment: .leading, spacing: 8) {
                Label(root == nil ? "\(card.peer.name) was removed from the organization" : "Read-only", systemImage: "lock").font(Theme.display(12, weight: .semibold))
                Text("The history remains available. New messages, edits and deletions are turned off.").font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary)
                if let draft = model.draft(root: root), !draft.text.isEmpty {
                    Text("Your unsent draft — kept on this Mac only").font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
                    Text(draft.text).font(Theme.display(12)).textSelection(.enabled)
                    HStack {
                        Button("Copy") {
                            guard let current = model.draft(root: root) else { return }
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(current.text, forType: .string)
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
    var writable: Bool { get }
    var problem: String? { get }
    func draft(root: String?) -> ChatDMContent.Draft?
    @discardableResult func saveDraft(_ text: String, root: String?) -> String?
    func send(_ text: String, root: String?, members: [(account: String, handle: String)], version: String?) -> Bool
    func openThread(_ id: String?)
    func conversationMessages(root: String?) -> [ChatMessage]
    func canEdit(_ message: ChatMessage) -> Bool
    @discardableResult func beginEditing(_ message: ChatMessage, root: String?, recovering: Bool) -> Bool
}

extension ChatDMModel: ChatDMComposing {}

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
    private var candidates: [ChatMentionCandidate] { members.filter { !$0.handle.isEmpty }.map { .init(id: $0.accountId, address: $0.handle, label: $0.name) } }
    private var token: (range: NSRange, query: String)? { ChatMentionCandidate.token(text, caret: selection.location) }
    private var matches: [ChatMentionCandidate] { dismissed ? [] : token.map { ChatMentionCandidate.filtered(candidates, query: $0.query) } ?? [] }
    private var mentionable: [(account: String, handle: String)] { members.map { ($0.accountId, $0.handle) } }
    private var canSend: Bool { isActive() && model.writable && version != nil && ChatChannelModel.textProblem(text) == nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let problem = model.problem { Text(problem).font(Theme.display(11)).foregroundStyle(ChatAppearance.failure) }
            VStack(spacing: 0) {
                ChatFormattingBar(control: control)
                ChatMentionEditor(text: $text, selection: $selection, candidates: candidates, autofocus: root != nil, control: control,
                    heightChanged: { height = $0 }, placeholder: root == nil ? "Message \(peer)" : "Reply…", accessibilityName: root == nil ? "Direct message" : "Reply",
                    suggestions: .init(sections: ChatMentionSection.grouped(matches), selected: min(candidateIndex, max(0, matches.count - 1)), title: "Mention a person", choose: choose),
                    attachments: rejectFiles, dropAttachments: rejectFiles, key: key)
                    .frame(height: height)
                HStack {
                    ChatIconButton(title: "Mention a person", symbol: "at") { control.insert("@") }
                    Spacer()
                    Button(action: send) { Image(systemName: "paperplane.fill").frame(width: 32, height: 28) }
                        .buttonStyle(.plain).foregroundStyle(canSend ? ChatAppearance.surface : ChatAppearance.secondary)
                        .background(canSend ? ChatAppearance.accent : Theme.chromeSelection, in: RoundedRectangle(cornerRadius: 5))
                        .disabled(!canSend).help("Send (↩)").accessibilityLabel("Send").chatFocusRing()
                }.padding(8)
            }.background(ChatAppearance.composerSurface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(control.focused ? ChatAppearance.accent : ChatAppearance.border, lineWidth: control.focused ? 2 : 1))
            if fileHint {
                HStack {
                    Text("Attachments aren't available in direct messages yet. Share files in a channel.")
                    Button("Dismiss") { fileHint = false }.buttonStyle(.link)
                }.font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
            }
            if root == nil {
                HStack {
                    Label("Only you and \(peer)", systemImage: "lock")
                    Spacer()
                    Text("Enter — send · ⇧Enter — new line")
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
    private func rejectFiles(_ pasteboard: NSPasteboard) -> Bool {
        guard ChatAttachmentPaste.accepts(pasteboard) else { return false }
        fileHint = true; return true
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
        if (code == 36 || code == 76), modifiers.intersection([.shift, .option, .control]).isEmpty, matches.isEmpty { send(); return true }
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
