import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

/// A single message canvas using the product's snapshot adapter, table, cell,
/// editor and action lifetimes. No SwiftUI message implementation is hosted.
@MainActor struct ChatNativeRowFixture: View {
    let model: any ChatConversationPresentation
    let message: ChatMessage
    let members: [ChatOrgView.Member]
    let mentionable: [(account: String, handle: String)]
    let me: String
    let archived: Bool
    var replies: Int = 0
    var requests: Int = 0
    var inThread = false
    var startsGroup = true
    var selected = false
    @State private var adapter = ChatTimelineAdapter()
    @AppStorage("chat.ux2.alwaysShowTime") private var alwaysShowTime = false
    @Environment(\.displayScale) private var scale
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        var calendar = self.calendar
        calendar.timeZone = timeZone
        let root = inThread ? model.threadRoot ?? message.threadRootId ?? message.id : nil
        let full = adapter.snapshot(model: model, root: root, members: members,
            mentionable: mentionable, me: me, archived: archived, ownerModel: nil,
            style: ChatTimelineAdapter.style(scale: scale, locale: locale, calendar: calendar,
                increasedContrast: contrast == .increased, alwaysShowTime: alwaysShowTime),
            selectedID: selected ? message.id : nil)
        let rows = full.rows.compactMap { row -> NativeTimelineSnapshot.Row? in
            guard row.messageID == message.id, case .message(let payload) = row.payload else { return nil }
            return .init(id: row.id, contentRevision: row.contentRevision, layoutRevision: row.layoutRevision,
                payload: .message(.init(content: payload.content, startsGroup: startsGroup, inThread: inThread)),
                visual: row.visual)
        }
        XCTAssertEqual(rows.count, 1, "The native row fixture must mount its requested message: " + message.id)
        let snapshot = NativeTimelineSnapshot(conversation: full.conversation,
            presentationEpoch: full.presentationEpoch, generation: full.generation, rows: rows,
            messageIDs: rows.compactMap(\.messageID), messageAliases: [:], members: full.members,
            mentionable: full.mentionable, me: full.me, style: full.style, state: full.state, commands: [])
        return ChatNativeRowCanvas(snapshot: snapshot, actions: adapter.actions)
            .onDisappear { adapter.invalidate() }
    }
}

@MainActor private struct ChatNativeRowCanvas: NSViewRepresentable {
    let snapshot: NativeTimelineSnapshot
    let actions: ChatTimelineActions?

    func makeCoordinator() -> NativeChatTimelineCoordinator { NativeChatTimelineCoordinator() }
    func makeNSView(context: Context) -> NativeChatTimelineContainer {
        context.coordinator.actions = actions
        let view = NativeChatTimelineContainer(coordinator: context.coordinator)
        view.update(snapshot)
        return view
    }
    func updateNSView(_ view: NativeChatTimelineContainer, context: Context) {
        context.coordinator.actions = actions
        view.update(snapshot)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeChatTimelineContainer,
                     context: Context) -> CGSize? {
        let width = proposal.width ?? 760
        let normalized = ChatTimelineWidth(width, scale: snapshot.style.metrics.scale)
        let height = snapshot.rows.reduce(CGFloat.zero) {
            $0 + context.coordinator.layoutEngine.plan($1, snapshot: snapshot, width: normalized).height
        }
        return CGSize(width: width, height: max(1, height))
    }
    static func dismantleNSView(_ view: NativeChatTimelineContainer, coordinator: NativeChatTimelineCoordinator) {
        coordinator.dispose()
    }
}
