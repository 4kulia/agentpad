import AppKit
import SwiftUI

/// Brutalist update prompt — matches the Settings window's visual language:
/// Theme.chrome* tokens, mono kebab-case labels, sharp corners, 1pt
/// hairlines, BracketButton actions. Replaces the system NSAlert so the
/// "Check for Updates…" flow doesn't fall out of AgentPad's design system.
struct UpdatePromptView: View {
    let outcome: UpdateChecker.Outcome
    let currentVersion: String
    let onClose: () -> Void
    let onDownload: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusLabel
                .padding(.bottom, 18)

            headline
            subtitle
                .padding(.top, 6)

            Rectangle()
                .fill(Theme.chromeHairline)
                .frame(width: 32, height: 1)
                .padding(.vertical, 22)

            content

            HStack(spacing: 10) {
                Spacer()
                actions
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 22)
        .frame(width: 460, alignment: .topLeading)
        .glassWindowBackground(fallback: Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
    }

    // MARK: Sections

    private var statusLabel: some View {
        Text(statusText)
            .font(Theme.mono(10, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(Theme.chromeMuted.opacity(0.85))
    }

    private var headline: some View {
        Text(headlineText)
            .font(Theme.display(28, weight: .medium))
            .foregroundStyle(Theme.chromeForeground)
    }

    private var subtitle: some View {
        Text(subtitleText)
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.chromeMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        switch outcome {
        case .newer(_, _, let notes) where !notes.isEmpty:
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "release-notes", bundle: .agentPadResources))
                    .font(Theme.mono(10, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Theme.chromeMuted.opacity(0.85))
                ScrollView {
                    Text(notes)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.chromeForeground)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 160)
                .bracketBorder()
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch outcome {
        case .newer(_, let url, _):
            BracketButton("later", action: onClose)
            BracketButton("update") {
                onDownload(url)
                onClose()
            }
        case .upToDate, .failed:
            BracketButton("done", action: onClose)
        }
    }

    // MARK: Copy

    private var statusText: String {
        let key: String
        switch outcome {
        case .newer: key = "UPDATE-AVAILABLE"
        case .upToDate: key = "UP-TO-DATE"
        case .failed: key = "CHECK-FAILED"
        }
        return String(
            localized: String.LocalizationValue(key),
            bundle: .agentPadResources
        )
    }

    private var headlineText: String {
        switch outcome {
        case .newer(let latest, _, _): return latest
        case .upToDate(let current): return current
        case .failed: return String(localized: "couldn't reach github", bundle: .agentPadResources)
        }
    }

    private var subtitleText: String {
        switch outcome {
        case .newer:
            return String.localizedStringWithFormat(
                String(localized: "current %@", bundle: .agentPadResources),
                currentVersion
            )
        case .upToDate: return String(localized: "you're on the latest release.", bundle: .agentPadResources)
        case .failed(let reason): return reason
        }
    }
}

@MainActor
final class UpdatePromptWindowController: NSWindowController {
    static let shared = UpdatePromptWindowController()

    private init() { super.init(window: nil) }
    required init?(coder: NSCoder) { fatalError() }

    static func present(outcome: UpdateChecker.Outcome, currentVersion: String) {
        let controller = shared
        controller.build(outcome: outcome, currentVersion: currentVersion)
        if controller.window?.isVisible != true {
            controller.window?.center()
        }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build(outcome: UpdateChecker.Outcome, currentVersion: String) {
        let view = UpdatePromptView(
            outcome: outcome,
            currentVersion: currentVersion,
            onClose: { [weak self] in self?.window?.close() },
            onDownload: { url in NSWorkspace.shared.open(url) }
        )
        let host = NSHostingController(rootView: view)
        // NSHostingController computes its preferred size from the SwiftUI
        // root; the .frame(width:) on UpdatePromptView fixes the width and
        // lets height self-size around the content (with or without release
        // notes). Without this, the window opens at NSWindow default size.
        host.sizingOptions = .preferredContentSize

        if let window {
            window.contentViewController = host
        } else {
            let new = NSWindow(contentViewController: host)
            new.title = String(localized: "Update", bundle: .agentPadResources)
            new.styleMask = [.titled, .closable]
            new.isReleasedWhenClosed = false
            new.appearance = Theme.windowAppearance
            new.configureGlassChrome()
            self.window = new
        }
    }
}
