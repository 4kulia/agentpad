import AppKit
import SwiftUI

struct ChatSidebarAgentCard: View {
    let agentID: String
    let active: ChannelRef?
    let window: NSWindow?
    let store: WorkspaceStore
    let model: ChatOrgModel?
    let close: () -> Void
    @State private var problem: String?

    var body: some View {
        let snapshot = ChatSidebarSnapshot(model: model, active: active)
        VStack(alignment: .leading, spacing: 12) {
            if let agent = snapshot.agents.first(where: { $0.id == agentID }), let model {
                HStack {
                    Text(agent.name).font(Theme.display(14, weight: .semibold))
                    Text("BOT").font(Theme.mono(10)).foregroundStyle(ChatSidebarStyle.secondary)
                }
                Text("Owner: \(agent.owner)").font(Theme.display(11)).foregroundStyle(ChatSidebarStyle.secondary)
                if !agent.description.isEmpty { Text(agent.description).font(Theme.display(12)) }
                Text(TeamAccessProfile(rawValue: agent.access)?.title ?? agent.access)
                    .font(Theme.display(11)).foregroundStyle(ChatSidebarStyle.secondary)
                if let active, let key = model.key, active.belongs(to: key), let card = model.visibleChannel(active.channel) {
                    if let member = model.agents(in: card.channelId).first(where: { $0.agentId == agentID }) {
                        Text("In #\(card.name)").font(Theme.display(11))
                        if member.enabled, member.address != nil, !card.archived {
                            Button("Mention in #\(card.name)") {
                                if ChatSidebarMention.insert(agentID: agentID, ref: active, window: window, model: model, store: store) { close() }
                                else { problem = "The channel editor is not available. Finish composing text and try again." }
                            }
                        }
                        if model.canRemoveAgent(member) {
                            Button("Remove from Channel…") { close(); ChatSidebarActions.removeAgent(member, from: card, model) }
                        }
                    } else if let own = model.addableAgents(card).first(where: { $0.agentId == agentID }) {
                        Button("Add to #\(card.name)…") { close(); ChatSidebarActions.addAgent(own, to: card, model) }
                    } else {
                        Text("This agent is not in #\(card.name).").font(Theme.display(11))
                    }
                } else {
                    Text("Open a channel to mention an agent.").font(Theme.display(11)).foregroundStyle(ChatSidebarStyle.secondary)
                }
                if agent.mine { Button("Published Agents…") { close(); TeamUI.showAgents() } }
                if let problem { Text(problem).font(Theme.display(11)).foregroundStyle(ChatSidebarStyle.secondary) }
            } else {
                Text("Agent unavailable").font(Theme.display(12))
            }
            Button("Close", action: close).keyboardShortcut(.cancelAction)
        }
        .padding(16).frame(width: 288, alignment: .leading)
        .foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
    }
}

/// Tab-host-scoped bridge to the existing NSTextView. Insertion goes through
/// AppKit's normal edit/undo delegate and UX1's changed/saveDraft path. It
/// neither writes a draft independently nor sends a message or calls an agent.
@MainActor
enum ChatSidebarMention {
    private static let editors = NSHashTable<ChatMentionEditor.Editor>.weakObjects()
    private final class Request {
        let agentID: String
        let ref: ChannelRef
        weak var window: NSWindow?
        weak var destination: NSView?
        weak var model: ChatOrgModel?
        let isActive: () -> Bool
        init(agentID: String, ref: ChannelRef, window: NSWindow, destination: NSView, model: ChatOrgModel,
             isActive: @escaping () -> Bool) {
            self.agentID = agentID; self.ref = ref; self.window = window; self.destination = destination
            self.model = model; self.isActive = isActive
        }
    }
    private static var pending: Request?

    static func register(_ editor: ChatMentionEditor.Editor) { editors.add(editor) }

    static func accepts(target: ChannelRef?, requested: ChannelRef, sameWindow: Bool, sameHost: Bool, visible: Bool, markedText: Bool) -> Bool {
        target == requested && sameWindow && sameHost && visible && !markedText
    }

    @discardableResult
    static func insert(agentID: String, ref: ChannelRef, window: NSWindow?, model: ChatOrgModel, store: WorkspaceStore) -> Bool {
        guard let session = store.active?.activeSession, session.channel == ref,
              let engine = session.engine as? ChannelTabEngine else { return false }
        return request(agentID: agentID, ref: ref, window: window, destination: engine.view, model: model,
            isActive: { [weak store, weak session] in
                guard let session else { return false }
                return store?.active?.activeSession === session
            }, openChannel: { engine.conversation.model?.openThread(nil) })
    }

    private static func address(agentID: String, ref: ChannelRef, model: ChatOrgModel) -> String? {
        guard let key = model.key, ref.belongs(to: key),
              let card = model.visibleChannel(ref.channel), !card.archived,
              let agent = model.agents(in: ref.channel).first(where: { $0.agentId == agentID && $0.enabled }),
              let address = agent.address else { return nil }
        return address
    }

    private static func editor(ref: ChannelRef, window: NSWindow, destination: NSView) -> ChatMentionEditor.Editor? {
        editors.allObjects.first {
            accepts(target: $0.navigationTarget, requested: ref, sameWindow: $0.window === window,
                    sameHost: $0 === destination || $0.isDescendant(of: destination),
                    visible: !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty, markedText: false)
        }
    }

    @discardableResult
    static func insert(agentID: String, ref: ChannelRef, window: NSWindow?, destination: NSView?, model: ChatOrgModel) -> Bool {
        guard let window, let destination, let address = address(agentID: agentID, ref: ref, model: model),
              let editor = editor(ref: ref, window: window, destination: destination),
              editor.isEditable, !editor.hasMarkedText() else { return false }
        let range = editor.selectedRange()
        let prefix = (editor.string as NSString).substring(to: range.location)
        let separator = prefix.isEmpty || prefix.last?.isWhitespace == true ? "" : " "
        editor.insertText(separator + "@\(address) ", replacementRange: range)
        window.makeFirstResponder(editor)
        return true
    }

    /// A narrow thread can hide the channel composer. Open it in this same
    /// host and deliver only after its normal draft restoration has finished.
    @discardableResult
    static func request(agentID: String, ref: ChannelRef, window: NSWindow?, destination: NSView, model: ChatOrgModel,
                        isActive: @escaping () -> Bool, openChannel: () -> Void) -> Bool {
        pending = nil
        guard let window, isActive(), address(agentID: agentID, ref: ref, model: model) != nil else { return false }
        if editor(ref: ref, window: window, destination: destination) != nil {
            return insert(agentID: agentID, ref: ref, window: window, destination: destination, model: model)
        }
        pending = Request(agentID: agentID, ref: ref, window: window, destination: destination, model: model, isActive: isActive)
        openChannel()
        return true
    }

    static func editorReady(_ editor: ChatMentionEditor.Editor) {
        guard pending != nil else { return }
        DispatchQueue.main.async { [weak editor] in
            guard let request = pending else { return }
            guard request.isActive(), let destination = request.destination, let window = request.window,
                  let model = request.model, address(agentID: request.agentID, ref: request.ref, model: model) != nil else {
                pending = nil; return
            }
            guard let editor, editor === self.editor(ref: request.ref, window: window, destination: destination) else { return }
            pending = nil
            insert(agentID: request.agentID, ref: request.ref, window: window, destination: destination, model: model)
        }
    }
}

@MainActor
final class ChatSidebarWindowReference { weak var window: NSWindow? }

struct ChatSidebarWindowReader: NSViewRepresentable {
    let reference: ChatSidebarWindowReference
    final class View: NSView {
        var reference: ChatSidebarWindowReference?
        override func viewDidMoveToWindow() { reference?.window = window }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> View {
        let view = View(); view.reference = reference; return view
    }
    func updateNSView(_ view: View, context: Context) { reference.window = view.window }
}
