import AppKit
import SwiftUI

/// About content, embedded in the Settings tab.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 78, height: 78)
                .padding(.bottom, 12)
            Text(AgentPadApp.name)
                .font(Theme.display(28, weight: .medium))
                .foregroundStyle(Theme.chromeForeground)
            Text(String.localizedStringWithFormat(
                String(localized: "Version %@", bundle: .agentPadResources),
                AgentPadApp.displayVersion
            ))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeMuted)
                .padding(.top, 4)
            Text(String(
                localized: String.LocalizationValue(AgentPadApp.tagline),
                bundle: .agentPadResources
            ))
                .font(Theme.display(12))
                .foregroundStyle(Theme.chromeMuted)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
            aboutLink("Github ↗", url: AgentPadApp.repositoryURL)
                .padding(.top, 14)
            Rectangle()
                .fill(Theme.chromeHairline)
                .frame(width: 32, height: 1)
                .padding(.vertical, 16)
            Text(String.localizedStringWithFormat(
                String(
                    localized: "© %@ %@ · MIT License",
                    bundle: .agentPadResources
                ),
                AgentPadApp.copyrightYear,
                AgentPadApp.author
            ))
                .font(Theme.mono(9))
                .foregroundStyle(Theme.chromeFaint)
        }
        .padding(.horizontal, 36)
        .padding(.top, 44)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
        .glassWindowBackground(fallback: Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
    }

    private func aboutLink(_ title: String, url: URL, font: Font = Theme.mono(11)) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text(title)
                .font(font)
                .foregroundStyle(Theme.chromeForeground)
        }
        .buttonStyle(.plain)
        .hoverCursor(.pointingHand)
    }
}
