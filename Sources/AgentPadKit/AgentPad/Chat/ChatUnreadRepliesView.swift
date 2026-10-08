import SwiftUI

struct ChatUnreadReplyBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count) new").font(Theme.display(11, weight: .semibold))
                .foregroundStyle(ChatAppearance.accent)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(ChatAppearance.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
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
