import SwiftUI

/// The shared entry point for channel, DM and both thread panes.
/// Models retain conversation state; AppKit owns timeline layout and scrolling.
struct ChatTimelineView: View {
    let model: any ChatConversationPresentation
    let root: String?
    let members: [ChatOrgView.Member]
    let mentionable: [(account: String, handle: String)]
    let me: String
    let archived: Bool
    let ownerModel: ChatChannelOwnerModel?

    var body: some View {
        ChatTimelineSnapshotHost(model: model, root: root, members: members, mentionable: mentionable,
                                 me: me, archived: archived, ownerModel: ownerModel) { snapshot, actions in
            AnyView(NativeChatTimelineRepresentable(snapshot: snapshot, actions: actions))
        }
    }
}
