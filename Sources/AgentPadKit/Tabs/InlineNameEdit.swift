import SwiftUI

@MainActor @Observable
final class InlineNameEdit {
    enum Key { case enter, escape }
    var text = ""
    private(set) var isEditing = false
    private(set) var error: String?

    func begin(_ value: String) {
        guard !isEditing else { return }
        text = value; error = nil; isEditing = true
    }
    static func problem(_ value: String) -> String? {
        value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            ? "The name can't contain control characters." : nil
    }
    func handle(_ key: Key, save: (String) -> String?) {
        guard isEditing else { return }
        switch key {
        case .escape: isEditing = false; error = nil
        case .enter:
            error = Self.problem(text) ?? save(text)
            if error == nil { isEditing = false }
        }
    }
}

struct InlineNameField: View {
    @Bindable var edit: InlineNameEdit
    let label: String
    let save: (String) -> String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField(label, text: $edit.text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
                .focused($focused)
                .onSubmit { edit.handle(.enter, save: save) }
                .onExitCommand { edit.handle(.escape, save: save) }
            if let error = edit.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { focused = true }
    }
}
