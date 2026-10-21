import AppKit
import SwiftUI

struct ChatSidebarAgentCard: View {
    let agentID: String
    let active: ChannelRef?
    let window: NSWindow?
    let store: WorkspaceStore
    let model: ChatOrgModel?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let model, let actions = ChatSidebarAgentActions(agentID: agentID, active: active, model: model) {
                let agent = actions.agent
                HStack(spacing: 12) {
                    ContactAvatar(stableID: agentID, name: agent.name, kind: .agent, size: 64, remote: .agent(agentID, model.key))
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(agent.name).font(Theme.display(20, weight: .semibold))
                            Text("BOT").font(Theme.mono(9)).foregroundStyle(.purple)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                        }
                        Text("Owner: \(agent.owner)").font(Theme.display(11)).foregroundStyle(ChatSidebarStyle.secondary)
                    }
                }
                let description = agent.description.isEmpty
                    ? model.view.myAgents.first(where: { $0.agentId == agentID })?.description ?? ""
                    : agent.description
                if !description.isEmpty { Text(description).font(Theme.display(12)) }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    fact("Rights", TeamAccessProfile(rawValue: agent.access)?.title ?? agent.access)
                        .help(TeamAccessProfile(rawValue: agent.access)?.summary ?? "")
                    let audience = publishedTo(actions, model: model)
                    if !audience.isEmpty { fact("Published to", audience) }
                    fact("Availability", [agent.enabled ? (agent.available ? "Online" : "Unavailable") : "Disabled", agent.device]
                        .compactMap { $0 }.joined(separator: " · "))
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(actions.channels, id: \.channelId) { channel in
                        HStack(spacing: 8) {
                            Button("Open #\(channel.name)") {
                                if !ChatSidebarAgentActions.open(agentID: agentID, channel: channel.channelId, model: model, show: {
                                    closeCard(); _ = store.showChannel($0)
                                }) { problem = "The agent's channel is no longer available." }
                            }.accessibilityIdentifier("publishedAgentOpenChannel-\(channel.channelId)")
                            if actions.mentionChannel?.channelId == channel.channelId {
                                mentionActions(channel, model: model)
                            }
                        }
                    }
                    if let channel = actions.mentionChannel, !actions.channels.contains(where: { $0.channelId == channel.channelId }) {
                        HStack(spacing: 8) { mentionActions(channel, model: model) }
                    }
                    HStack(spacing: 8) {
                        if agent.mine {
                            Button("Edit publication…") {
                                guard let current = ChatSidebarAgentActions(agentID: agentID, active: active, model: model), current.agent.mine,
                                      let editing = TeamAgentEditing.resolve(agentID: agentID, key: current.key,
                                          currentKey: TeamService.shared.calls.serverKey, agents: TeamService.shared.calls.agents) else {
                                    problem = "This publication cannot be edited here. Open it on the Mac that publishes this agent."; return
                                }
                                TeamTabs.shared.showPublication(editing, from: store)
                            }
                        } else {
                            Button("Ask…") { ChatSidebarActions.askAgent(actions, model, from: store) }
                                .disabled(actions.address == nil)
                        }
                        Button("Published Agents…") { TeamTabs.shared.showAgents(from: store) }
                    }
                }
                if let problem { Text(problem).font(Theme.display(11)).foregroundStyle(ChatSidebarStyle.secondary) }
            } else {
                Text("Agent unavailable").font(Theme.display(12))
            }
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
        .accessibilityIdentifier("publishedAgentCard")
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).font(Theme.display(11)).foregroundStyle(ChatSidebarStyle.secondary)
            Text(value).font(Theme.display(12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func publishedTo(_ actions: ChatSidebarAgentActions, model: ChatOrgModel) -> String {
        let channels = actions.channels.map { channel in
            [model.channelTeams.first(where: { $0.teamId == channel.teamId })?.name, "# \(channel.name)"]
                .compactMap { $0 }.joined(separator: " · ")
        }
        if !channels.isEmpty { return channels.joined(separator: ", ") }
        let teams = model.view.myAgents.first(where: { $0.agentId == agentID })?.teamIds ?? []
        return model.channelTeams.filter { teams.contains($0.teamId) }.map(\.name).joined(separator: ", ")
    }

    @ViewBuilder private func mentionActions(_ channel: ChatChannelCard, model: ChatOrgModel) -> some View {
        Button("Mention in #\(channel.name)") {
            guard let current = ChatSidebarAgentActions(agentID: agentID, active: active, model: model),
                  current.mentionChannel?.channelId == channel.channelId else { return }
            let ref = ChannelRef(current.key, channel: channel.channelId)
            let window = window ?? store.active?.activeSession?.engine.view.window
            closeCard()
            _ = store.showChannel(ref)
            if !ChatSidebarMention.insert(agentID: agentID, ref: ref, window: window, model: model, store: store) {
                problem = "The channel editor is not available. Finish composing text and try again."
            }
        }.accessibilityIdentifier("publishedAgentMention")
        if let member = model.agents(in: channel.channelId).first(where: { $0.agentId == agentID }) {
            if model.canRemoveAgent(member) {
                Button("Remove from Channel…", role: .destructive) {
                    ChatSidebarActions.removeAgent(member, from: channel, model, from: store)
                }.buttonStyle(PopupDestructiveButtonStyle())
            }
        } else if let own = model.addableAgents(channel).first(where: { $0.agentId == agentID }) {
            Button("Add to #\(channel.name)…") { ChatSidebarActions.addAgent(own, to: channel, model, from: store) }
        }
    }

    private func closeCard() {
        guard case .tool(let session) = store.popups.page,
              case .agent(_, let id) = session.toolRoute, id == agentID else { return }
        store.popups.dismiss(session, reason: .applied)
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
            }, openChannel: { engine.conversation.showChannelComposer() })
    }

    private static func address(agentID: String, ref: ChannelRef, model: ChatOrgModel) -> String? {
        guard let key = model.key, ref.belongs(to: key),
              let actions = ChatSidebarAgentActions(agentID: agentID, active: ref, model: model),
              actions.mentionChannel != nil, let address = actions.address else { return nil }
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

    /// A narrow thread or pin panel can hide the channel composer. Open it in this same
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
final class ChatSidebarWindowReference { weak var window: NSWindow?; weak var view: NSView? }

struct ChatSidebarWindowReader: NSViewRepresentable {
    let reference: ChatSidebarWindowReference
    final class View: NSView {
        var reference: ChatSidebarWindowReference?
        override func viewDidMoveToWindow() { reference?.window = window }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> View {
        let view = View(); view.reference = reference; reference.view = view; return view
    }
    func updateNSView(_ view: View, context: Context) { reference.window = view.window }
}
