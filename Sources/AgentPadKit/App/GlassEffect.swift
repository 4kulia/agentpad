import AppKit
import GhosttyKit
import SwiftUI

/// macOS 26 Liquid Glass, opt-in via ghostty's `background-blur = macos-glass-*`.
///
/// The real effect is AppKit's `NSGlassEffectView`, which only exists in the
/// macOS 26 SDK — so the wrapper below is fenced behind `#if compiler(>=6.2)`
/// (the toolchain that ships that SDK) and `@available(macOS 26.0, *)` for the
/// runtime check. This is a macOS 26+ feature on purpose: older systems can
/// only manage an `NSVisualEffectView` frost that looks nothing like real
/// glass, so on macOS 14/15 the chrome stays opaque (no effect) rather than
/// shipping a poor imitation.

#if compiler(>=6.2)
/// `NSGlassEffectView` that never participates in hit-testing. The glass is
/// pure decoration, but SwiftUI does NOT keep platform NSViews' AppKit
/// z-order aligned with the conceptual layer order after structural changes:
/// after a pane split, the ORIGINAL pane's terminal NSView sat BELOW this
/// glass while the new pane's sat above — so every click on the old pane
/// (terminal content AND its tab bar) landed on the glass and died, making
/// click-to-focus a split sibling impossible while glass was on. A visual
/// backdrop must swallow no events regardless of where the z-order shuffle
/// puts it; returning nil skips this whole subtree (the internal
/// ContentHolderView included) in one place.
@available(macOS 26.0, *)
private final class PassthroughGlassView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One real `NSGlassEffectView` bridged into SwiftUI as a background layer.
/// Content-less — an empty glass view renders the effect tinted toward
/// `tint`, which is exactly how ghostty uses it at the window level.
@available(macOS 26.0, *)
private struct GlassEffectLayer: NSViewRepresentable {
    let style: Theme.GlassStyle
    let tint: NSColor

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = PassthroughGlassView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSGlassEffectView) {
        view.style = style.official
        view.tintColor = tint
    }
}
#endif

extension View {
    /// Backmost window layer. On macOS 26 with a glass style configured this
    /// is the single real `NSGlassEffectView` that every chrome panel sits in
    /// front of and lets read through. Otherwise (glass off, or any system
    /// below macOS 26) it's the opaque `fallback` — pass the terminal surface
    /// color so the window edge stays seamless with the terminal, matching
    /// AgentPad's pre-glass look exactly.
    func glassWindowBackground(fallback: Color) -> some View {
        // `.ignoresSafeArea()` lets the backing fill the whole window —
        // including under a transparent titlebar — while the foreground
        // content still respects the titlebar safe area. That's what keeps
        // the glass seamless on titled windows (Settings, Update) instead of
        // leaving an unglassed titlebar strip.
        background { GlassWindowBacking(fallback: fallback).ignoresSafeArea() }
    }

    /// Chrome panel background (sidebar, status bar, right panel). When glass
    /// is actively rendering (macOS 26 + a style set) it's a translucent chrome
    /// tint so the window glass shows through; otherwise the opaque chrome
    /// color — identical to AgentPad's pre-glass chrome on every system below
    /// macOS 26.
    func glassChromeBackground() -> some View {
        background(Theme.glassEnabled ? Theme.glassPanelTint : Theme.chromeBackground)
    }
}

/// The window's backmost layer: real glass on macOS 26 (with ghostty-style
/// inactive masking), the opaque `fallback` otherwise. Reads
/// `controlActiveState` so it can cover the glass with the theme tint when the
/// window isn't key — without that, macOS washes inactive glass to a flat gray.
private struct GlassWindowBacking: View {
    let fallback: Color
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let style = Theme.glassStyle {
            GlassEffectLayer(style: style, tint: Theme.glassTint)
                .overlay {
                    // Not the key window → mask the macOS gray with the theme
                    // tint so the whole window dims uniformly to the surface
                    // color instead of going half-gray.
                    if activeState != .key {
                        Theme.glassInactiveTint
                    }
                }
        } else {
            translucentFallback
        }
        #else
        translucentFallback
        #endif
    }

    /// The non-glass window backing follows `background-opacity` ONLY when a
    /// numeric `background-blur` provides the frosting (bare opacity stays
    /// opaque — see `applyGlassBacking`). Reads the settings.json values via
    /// the model so SwiftUI observes live edits; values set only in an
    /// inherited ghostty config apply at the window layer but keep this
    /// backing opaque — a recorded settings.json-first boundary.
    private var translucentFallback: some View {
        let model = AgentPadSettingsModel.shared
        let frosted = model.backgroundBlur.map {
            !AgentPadSettings.isBlurExplicitlyOff($0) && !AgentPadSettings.isGlassBlur($0)
        } ?? false
        return fallback.opacity(frosted ? (model.backgroundOpacity ?? 1) : 1)
    }
}

extension NSWindow {
    /// Match the window's backing to the current glass + opacity state —
    /// non-opaque + clear when the glass layer needs to sample the desktop
    /// OR `background-opacity < 1` wants it showing through (opacity works
    /// WITHOUT glass, on every macOS — the core renders the surface with
    /// alpha, the window just has to let it through). Call at window
    /// creation and from `refreshThemeAppearances` so live edits flip every
    /// window in step.
    @MainActor func applyGlassBacking() {
        let glass = Theme.glassEnabled
        // Translucency needs a frosting layer under it — Liquid Glass or the
        // core's window blur. BARE opacity stays opaque by design: AgentPad's
        // layered chrome (inactive-pane dimming × surface alpha × sidebar ×
        // top strip) multiplies to visibly different levels with nothing
        // frosted underneath to absorb the difference.
        let translucent = glass || LibghosttyApp.shared.hostConfig.windowBlurRadius > 0
        isOpaque = !translucent
        backgroundColor = translucent ? .clear : nil
        // ghostty's own window blur (`background-blur = true` or a radius) —
        // the traditional frosted look, works on every macOS. The call reads
        // the config value itself; under glass we must CLEAR instead: the
        // core call can't do it (it early-returns at opacity ≥ 1 and would
        // pass the glass sentinel's negative cval as a radius), so a live
        // numeric-blur → glass switch would leave the old CGS radius stacked
        // under the glass until the window is rebuilt (Codex P2).
        if !glass, let app = LibghosttyApp.shared.app {
            ghostty_set_window_background_blur(app, Unmanaged.passUnretained(self).toOpaque())
        } else if glass {
            clearNativeWindowBlur()
        }
    }

    /// Zeroes the CGS background-blur radius the core's
    /// `ghostty_set_window_background_blur` may have installed earlier. Same
    /// private CGS calls the core links (resolved at runtime; silently a
    /// no-op if the symbols ever vanish). Idempotent — glass windows render
    /// their blur via NSGlassEffectView, untouched by a zero CGS radius.
    @MainActor private func clearNativeWindowBlur() {
        typealias ConnectionFn = @convention(c) () -> UnsafeMutableRawPointer
        typealias SetBlurFn = @convention(c) (UnsafeMutableRawPointer, Int, Int32) -> Int32
        guard let connSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSDefaultConnectionForThread"),
              let setSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetWindowBackgroundBlurRadius")
        else { return }
        let connection = unsafeBitCast(connSym, to: ConnectionFn.self)()
        _ = unsafeBitCast(setSym, to: SetBlurFn.self)(connection, windowNumber, 0)
    }

    /// The glass-titlebar recipe shared by AgentPad's titled auxiliary windows
    /// (Settings, About, Update): a transparent full-size titlebar so the
    /// glass backing runs edge to edge, plus the backing itself. Without the
    /// transparent full-size titlebar the glass leaves an unglassed strip up
    /// top. Callers still set their own `styleMask` base, size, and title.
    @MainActor func configureGlassChrome() {
        styleMask.insert(.fullSizeContentView)
        titlebarAppearsTransparent = true
        applyGlassBacking()
    }
}
