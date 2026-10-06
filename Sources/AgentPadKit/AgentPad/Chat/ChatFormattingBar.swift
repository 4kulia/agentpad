import SwiftUI

struct ChatFormattingBar: View {
    let control: ChatEditorControl
    var body: some View {
        HStack(spacing: 2) {
            ForEach(ChatMarkdownInsertion.allCases, id: \.self) { command in
                ChatIconButton(title: command.title, symbol: command.symbol) { control.format(command) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.chromeHover)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.chromeSeparator).frame(height: 1) }
    }
}
