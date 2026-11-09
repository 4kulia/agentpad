import SwiftUI

struct ChatUnreadReplyBadge: View {
    let count: Int
    private func mediaParityID(_ part: String) -> String {
        #if DEBUG
        ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_W06_CAPTURE"] == "1"
            || ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_W07_CAPTURE"] == "1" ? "w06/replies/" + part : ""
        #else
        ""
        #endif
    }

    var body: some View {
        if count > 0 {
            Text("\(count) new").font(Theme.display(11, weight: .semibold))
                .foregroundStyle(ChatAppearance.accent)
                .chatParity(mediaParityID("unread-text"), "text", text: "\(count) new",
                    colors: ["foreground": ChatAppearance.accent], font: Theme.display(11, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(ChatAppearance.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .chatParity(mediaParityID("unread"), "control", colors: ["background": ChatAppearance.accent.opacity(0.12)])
                .accessibilityHidden(true) // Included in the reply button's label.
        }
    }
}

/// Kept above the scroll view so replies to older roots remain discoverable.
struct ChatUnreadThreadsBanner: View {
    let model: ChatChannelModel

    var body: some View {
        if let root = model.feed.firstUnloadedUnreadThread {
            Button {
                model.pins.close()
                model.openThread(root)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text("Unread thread replies: \(model.feed.unloadedUnreadReplyCount)")
                        #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
                        .chatReviewParity("caller/unread-threads", text: "Unread thread replies: \(model.feed.unloadedUnreadReplyCount)", colors: ["foreground": ChatAppearance.accent])
                        #endif
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                }.font(Theme.display(11, weight: .medium))
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(ChatAppearance.accent)
                .background(ChatAppearance.accent.opacity(0.06)).chatFocusRing()
                .help("Open the first unread thread outside the loaded messages")
        }
    }
}
