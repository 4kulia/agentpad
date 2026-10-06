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
    private var tint: Color {
        if identity.isBot { return ChatAppearance.accent }
        let light = Theme.resolved.isLight
        switch identity.colorIndex {
        case 0: return light ? Color(red: 0.46, green: 0.29, blue: 0.13) : Color(red: 0.91, green: 0.76, blue: 0.62)
        case 1: return light ? Color(red: 0.24, green: 0.35, blue: 0.48) : Color(red: 0.67, green: 0.82, blue: 0.90)
        case 2: return light ? Color(red: 0.26, green: 0.40, blue: 0.29) : Color(red: 0.69, green: 0.82, blue: 0.72)
        default: return light ? Color(red: 0.42, green: 0.30, blue: 0.52) : Color(red: 0.84, green: 0.78, blue: 0.89)
        }
    }
    var body: some View {
        Group {
            if identity.isBot { Image(systemName: "sparkles").font(.system(size: size * 0.53)) }
            else { Text(ChatAuthorIdentity.initials(name)).font(Theme.display(size * 0.37, weight: .semibold)) }
        }
        .foregroundStyle(tint).frame(width: size, height: size)
        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.31))
        .accessibilityHidden(true)
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
