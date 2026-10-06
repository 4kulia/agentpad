import AppKit
import SwiftUI

@MainActor
enum ChatFocusMenu {
    static func make(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "Chat Focus")
        for area in ChatFocusArea.allCases {
            let item = NSMenuItem(title: area.title, action: action, keyEquivalent: "")
            item.target = target
            item.tag = area.rawValue
            menu.addItem(item)
        }
        return menu
    }
}

private struct ChatFocusRing: ViewModifier {
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.focused($focused)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(focused ? ChatAppearance.accent : .clear, lineWidth: contrast == .increased ? 3 : 2)
                .allowsHitTesting(false))
    }
}

extension View {
    func chatFocusRing() -> some View { modifier(ChatFocusRing()) }
}

@MainActor
enum ChatAccessibility {
    static func delivery(from old: ChatMessage, to new: ChatMessage) -> String? {
        guard old.id == new.id else { return nil }
        if old.localState != new.localState {
            if new.localState == .failed { return "Message not sent: " + ChatChannelModel.reason(new.localError) }
            if old.localState == .sending, new.localState == nil, new.hasMutable { return "Message sent" }
        }
        if old.localEdit?.state == "saving", new.localEdit?.state != "saving" {
            if new.localEdit?.state == "failed" { return "Message change failed: " + ChatChannelModel.reason(new.localEdit?.error) }
            return new.deleted ? "Message deleted" : "Message saved"
        }
        return nil
    }

    static func agent(from old: ChatSourceStatus, to new: ChatSourceStatus) -> String? {
        guard old.id == new.id, old.state != new.state || old.publication != new.publication || old.error != new.error,
              ["finished", "failed", "declined", "cancelled", "stopped", "lost"].contains(new.state) else { return nil }
        return "\(new.agent), BOT, \(new.word)"
    }

    static func announce(_ text: String, in view: NSView?) {
        guard let view, let window = view.window, window.isKeyWindow,
              !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
