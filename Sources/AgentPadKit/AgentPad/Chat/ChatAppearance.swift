import AppKit
import SwiftUI

/// Chat-specific readable captions and accents derived from the active Theme.
/// Kept outside Theme.swift so the navigation package can evolve independently.
@MainActor
enum ChatAppearance {
    static var surface: Color { Color(nsColor: Theme.terminalSurface) }
    static var secondary: Color {
        Color(nsColor: Theme.resolved.foregroundColor.blended(withFraction: Theme.resolved.isLight ? 0.25 : 0.30,
                                                             of: Theme.terminalSurface) ?? .secondaryLabelColor)
    }
    static var accent: Color { Theme.resolved.isLight ? Color(red: 0.13, green: 0.38, blue: 0.55) : Theme.activityRunning }
    static var attention: Color { Theme.resolved.isLight ? Color(red: 0.51, green: 0.31, blue: 0.09) : Theme.activityAttention }
    static var success: Color { Theme.resolved.isLight ? Color(red: 0.20, green: 0.43, blue: 0.25) : Theme.activitySuccess }
    static var failure: Color { Theme.resolved.isLight ? Color(red: 0.68, green: 0.18, blue: 0.18) : Theme.activityFailure }
    static var border: Color {
        Theme.chromeForeground.opacity(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.65 : 0.22)
    }
    /// Opaque even with Reduce Transparency; blends the two resolved surfaces.
    static var composerSurface: Color {
        Color(nsColor: Theme.terminalSurface.blended(withFraction: 0.45, of: NSColor(Theme.chromeBackground)) ?? Theme.terminalSurface)
    }
}

struct ChatBotBadge: View {
    var body: some View {
        Text("BOT").font(Theme.mono(9)).foregroundStyle(ChatAppearance.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.chromeForeground.opacity(0.19)))
            .accessibilityLabel("Bot")
    }
}

struct ChatAvatar: View {
    let identity: ChatAuthorIdentity
    let name: String
    var size: CGFloat = 32
    var body: some View {
        ContactAvatar(stableID: identity.avatarID, name: name, kind: identity.isBot ? .agent : .person, size: size)
    }
}

struct ChatIconButton: View {
    let title: String
    let symbol: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 28, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(ChatAppearance.secondary).help(title).accessibilityLabel(title)
            .chatFocusRing()
    }
}
