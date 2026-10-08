import SwiftUI

/// The actual tab popover, also hosted directly by layout regression tests.
struct AgentPadTabMenu: View {
    let tab: Session
    let canCloseToRight: Bool
    let dismiss: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseToRight: () -> Void
    let onDuplicate: () -> Void
    let onRename: () -> Void
    let onSplit: (SplitOrientation) -> Void
    let onMoveToNewWindow: () -> Void
    let onLastAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // AgentPad: all export entry points share the provenance gate.
            if AgentAnswerSource.supports(tab) {
                let problem = AgentAnswerSource.problem(tab)
                AgentPadMenuRow(title: "Copy as Markdown", shortcut: "⌘⇧C", isDisabled: problem != nil) {
                    dismiss()
                    onLastAnswer(true)
                }
                .help(problem?.rawValue ?? "Copy last agent answer as Markdown")
                AgentPadMenuRow(title: "Forward…", shortcut: "⌘⇧F", isDisabled: problem != nil) {
                    dismiss()
                    onLastAnswer(false)
                }
                .help(problem?.rawValue ?? "Forward last agent answer…")
                if let problem {
                    AgentAnswerMenuExplanation(problem: problem)
                }
                AgentPadMenuDivider()
            }
            AgentPadMenuRow(title: "Close Tab", shortcut: "⌘W") {
                dismiss()
                onClose()
            }
            AgentPadMenuRow(title: "Close Other Tabs") {
                dismiss()
                onCloseOthers()
            }
            AgentPadMenuRow(title: "Close Tabs to the Right", isDisabled: !canCloseToRight) {
                dismiss()
                onCloseToRight()
            }
            AgentPadMenuDivider()
            AgentPadMenuRow(title: "Split Right", shortcut: "⌘D") {
                dismiss()
                onSplit(.horizontal)
            }
            AgentPadMenuRow(title: "Split Down", shortcut: "⌘⇧D") {
                dismiss()
                onSplit(.vertical)
            }
            AgentPadMenuRow(title: "Move to New Window") {
                dismiss()
                onMoveToNewWindow()
            }
            AgentPadMenuDivider()
            // AgentPad: a chat tab takes its destination’s name (DESIGN-F2).
            if tab.hasProcess {
                AgentPadMenuRow(title: "Rename Tab…", shortcut: "⌘R") {
                    dismiss()
                    onRename()
                }
            }
            AgentPadMenuRow(title: "Duplicate Tab") {
                dismiss()
                onDuplicate()
            }
            AgentPadMenuDivider()
            RevealInFinderMenuRow(url: tab.currentDirectory) { dismiss() }
        }
        .padding(Theme.space1)
        .frame(width: 300)
        .background(Theme.chromeBackground)
    }
}

struct AgentAnswerMenuExplanation: View {
    let problem: AgentAnswerTranscript.Problem

    var body: some View {
        Text(problem.rawValue).font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
            .fixedSize(horizontal: false, vertical: true).padding(8)
    }
}
