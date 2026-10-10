import SwiftUI

/// The same editor chrome and attachment controls for channels and DMs.
struct ChatComposerBox<Editor: View>: View {
    let control: ChatEditorControl
    let attachments: ChatAttachmentManager?
    let owner: ChatAttachmentOwner?
    let root: String?
    let fileUI: Bool
    let mentionTitle: String
    let canSend: Bool
    let chooseFiles: () -> Void
    let send: () -> Void
    @ViewBuilder var editor: () -> Editor
    @AppStorage("chat.ux2.formatting") private var formatting = true

    var body: some View {
        VStack(spacing: 0) {
            if let attachments, let owner { ChatAttachmentDraftStrip(manager: attachments, owner: owner, root: root) }
            if formatting { ChatFormattingBar(control: control) }
            editor()
            HStack(spacing: 2) {
                if fileUI { ChatIconButton(title: "Attach files", symbol: "paperclip", action: chooseFiles) }
                ChatIconButton(title: "Insert emoji", symbol: "face.smiling", action: control.emoji)
                ChatIconButton(title: mentionTitle, symbol: "at") { control.insert("@") }
                Button("Aa") { formatting.toggle() }.buttonStyle(.plain).frame(width: 28, height: 28)
                    .help("Show formatting").accessibilityLabel("Show formatting").accessibilityValue(formatting ? "Shown" : "Hidden").chatFocusRing()
                Spacer()
                Button(action: send) { Image(systemName: "paperplane.fill").frame(width: 32, height: 28) }
                    .buttonStyle(.plain).foregroundStyle(canSend ? ChatAppearance.surface : ChatAppearance.secondary)
                    .background(canSend ? ChatAppearance.accent : Theme.chromeSelection, in: RoundedRectangle(cornerRadius: 5))
                    .disabled(!canSend).help("Send (⌘↩)").accessibilityLabel("Send").chatFocusRing()
            }.padding(.horizontal, 8).padding(.bottom, 8)
        }
        .background(ChatAppearance.composerSurface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(control.focused ? ChatAppearance.accent : ChatAppearance.border, lineWidth: control.focused ? 2 : 1))
    }
}
