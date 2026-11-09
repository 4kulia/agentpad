import AppKit
import SwiftUI

/// SwiftUI sizing bridge for the shared, selectable AppKit message renderer.
struct ChatMentionText: NSViewRepresentable {
    @Environment(\.chatParityEnabled) private var parityEnabled
    @Environment(\.chatParityMessage) private var parityMessage
    var markdown: String
    var addresses: [String]
    var fontSize: CGFloat = 14

    typealias MessageTextView = ChatMessageText.View
    typealias Coordinator = ChatMessageText.Coordinator

    static func attributed(_ markdown: String, addresses: [String], fontSize: CGFloat = 14) -> NSAttributedString {
        ChatMessageText.attributed(markdown, addresses: addresses, fontSize: fontSize)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSTextView { ChatMessageText.makeView(delegate: context.coordinator) }
    func updateNSView(_ view: NSTextView, context: Context) {
        #if DEBUG
        if parityEnabled && !parityMessage.isEmpty { view.identifier = .init("chat-parity:" + parityMessage + "/body") }
        #endif
        let cached = context.coordinator
        let style = ChatMessageText.style
        guard cached.markdown != markdown || cached.addresses != addresses
                || cached.fontSize != fontSize || cached.style != style else { return }
        let content = Self.attributed(markdown, addresses: addresses, fontSize: fontSize)
        cached.markdown = markdown; cached.addresses = addresses
        cached.fontSize = fontSize; cached.style = style
        ChatMessageText.setContent(content, in: view)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
}
