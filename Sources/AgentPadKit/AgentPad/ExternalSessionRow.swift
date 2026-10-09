import AppKit
import SwiftUI

/// What you can do about a session running in another terminal: jump to its
/// tab, or move the conversation into a tab here.
@MainActor
enum ExternalSessionActions {
    static func focus(_ session: ExternalAgentSession) {
        Task { @MainActor in
            if await ExternalSessionMonitor.shared.focus(session) == .noTerminalFound {
                showFailure(
                    title: "Couldn't find this session's window",
                    message: "It isn't running in a terminal app this Mac can bring forward (for example, it runs inside tmux or over SSH).", session: session
                )
            }
        }
    }

    static func takeOver(_ session: ExternalAgentSession, into store: WorkspaceStore) {
        ProcessTabs.shared.importExternal(session, from: store)
    }

    static func showFailure(title: String, message: String, session: ExternalAgentSession? = nil, from store: WorkspaceStore? = nil) {
        if let session, let model = ProcessTabs.shared.importExternal(session, from: store) {
            model.message = title + "\n" + message
        } else if let tab = TabRouter.shared.open(.importSession(agentID: "", conversationID: "", externalSourceID: UUID().uuidString), from: store) {
            tab.tabState?.message = title + "\n" + message
        }
    }

}

struct SessionSectionLabel: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(Theme.display(10, weight: .semibold))
                .foregroundStyle(Theme.chromeMuted)
            Text("\(count)")
                .font(Theme.mono(10, weight: .medium))
                .foregroundStyle(Theme.chromeMuted.opacity(0.75))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

struct ExternalSessionRow: View {
    let session: ExternalAgentSession
    let isTakingOver: Bool
    let onFocus: () -> Void
    let onTakeOver: () -> Void
    var onShowFiles: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            AgentIconView(
                asset: AgentTemplate.claudeCode.iconAsset,
                fallbackSymbol: AgentTemplate.claudeCode.symbol,
                size: 16
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle)
                    .font(Theme.display(12.5, weight: .medium))
                    .foregroundStyle(Theme.chromeForeground)
                    .lineLimit(1)
                Text(locationLine)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
            if isTakingOver {
                ProgressView().controlSize(.small)
            } else if isHovered {
                actionButtons
            } else {
                stateLabel
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, Theme.sidebarRowVerticalPadding)
        .background(isHovered ? Theme.chromeHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chromeSelectionCornerRadius, style: .continuous))
        .padding(.horizontal, Theme.space2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onFocus)
        .contextMenu {
            Button("Go to Terminal Window", action: onFocus)
            if let onShowFiles { Button("Show Files", action: onShowFiles) }
            Button("Move Here", action: onTakeOver).disabled(!session.canTakeOver)
            // AgentPad: team work.
            Divider()
            TeamPublishMenu(sessionId: session.sessionId, title: session.displayTitle)
        }
        .help(helpText)
    }

    private var stateLabel: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(stateWord)
                .font(Theme.display(10, weight: .medium))
                .foregroundStyle(agentStateWordColor(session.monitorState))
            if let since = session.statusSince {
                // Re-render once a minute so the age doesn't freeze.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(relativeAgeTier(context.date.timeIntervalSince(since)))
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.chromeMuted.opacity(0.75))
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            if let onShowFiles {
                HoverableIconButton(systemName: "folder", fontSize: 11, size: 22, help: "Show this session's files", action: onShowFiles)
            }
            HoverableIconButton(systemName: "macwindow", fontSize: 11, size: 22, help: "Go to terminal window", action: onFocus)
            if session.canTakeOver {
                HoverableIconButton(systemName: "arrow.down.to.line", fontSize: 11, size: 22, help: "Move here", action: onTakeOver)
            }
        }
    }

    private var stateWord: String {
        if case .other(let raw) = session.status { return raw }
        return session.monitorState.label
    }

    private var locationLine: String {
        let path = (session.cwd.path as NSString).abbreviatingWithTildeInPath
        guard let tty = session.tty else { return path }
        return "\(path) · \(tty)"
    }

    private var helpText: String {
        var lines = [singleLine(session.displayTitle)]
        if case .waiting(let reason?) = session.status { lines.append("Waiting: \(reason)") }
        lines.append(locationLine)
        lines.append("Click to go to its terminal window")
        return lines.joined(separator: "\n")
    }
}
