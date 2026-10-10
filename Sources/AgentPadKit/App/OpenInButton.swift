import AppKit
import SwiftUI

/// Top-chrome "Open in <app>" split control, modelled on codex's. The left
/// zone shows the last-used (or first available) app's icon — clicking it
/// opens the active tab's cwd in that app. The right zone is a chevron that
/// opens the full picker. State (order / hidden / last-used) lives in
/// `AgentPadSettingsModel`; the directory comes from the active session.
struct OpenInButton: View {
    @Bindable var store: WorkspaceStore
    private var model: AgentPadSettingsModel { AgentPadSettingsModel.shared }

    @State private var isMenuOpen = false
    @State private var iconHovered = false
    @State private var chevronHovered = false

    var body: some View {
        let visible = OpenInResolver.visibleApps(model: model)
        let primary = OpenInApp.effectiveDefault(lastUsedId: model.lastOpenInAppId, visible: visible)
        let dir = currentDirectory
        let canOpen = dir != nil && primary != nil
        let primaryLabel = openInLabel(for: primary)

        HStack(spacing: 0) {
            Button {
                if let dir, let primary { choose(primary, dir: dir) }
            } label: {
                Group {
                    if let primary {
                        OpenInAppIcon(app: primary, size: Theme.chromeOpenInIconSize)
                    } else {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(iconHovered ? Theme.chromeForeground : Theme.chromeMuted)
                    }
                }
                .frame(
                    width: Theme.chromeToolbarButtonSize,
                    height: Theme.chromeToolbarButtonSize
                )
                .background(iconHovered ? Theme.chromeHover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canOpen)
            .onHover { iconHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: iconHovered)
            .accessibilityLabel(primaryLabel)
            .help(primaryLabel)

            Button {
                if !visible.isEmpty {
                    OpenInResolver.invalidate()
                    isMenuOpen.toggle()
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(chevronHovered ? Theme.chromeForeground : Theme.chromeMuted)
                    .frame(
                        width: Theme.chromeSplitChevronWidth,
                        height: Theme.chromeToolbarButtonSize
                    )
                    .background(
                        isMenuOpen
                            ? Theme.chromeActive
                            : (chevronHovered ? Theme.chromeHover : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(visible.isEmpty)
            .onHover { chevronHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: chevronHovered)
            .accessibilityLabel(String(localized: "Open in…", bundle: .agentPadResources))
            .help(String(localized: "Open in…", bundle: .agentPadResources))
            .attentionPopover(isPresented: $isMenuOpen, arrowEdge: .bottom) {
                picker(visible: visible, dir: dir)
            }
        }
        // A borderless toolbar split button: the two actions share one clipped
        // surface and compact geometry; the hairline is the only seam. This
        // keeps it related without giving it chrome that sibling buttons lack.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.chromeSeparator)
                .frame(width: 1, height: Theme.chromeToolbarButtonSize - 10)
                .offset(x: Theme.chromeToolbarButtonSize)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.chromeButtonCornerRadius))
        // Dim only when no apps are installed at all (cwd-independent —
        // `primary != nil` already implies `!visible.isEmpty`).
        .opacity(visible.isEmpty ? 0.4 : 1)
    }

    /// `visible` is computed once in `body`; the chevron handler `invalidate()`s
    /// before opening, so that value is already the fresh post-invalidate list —
    /// no need to recompute it here.
    private func picker(visible: [OpenInApp], dir: URL?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if visible.isEmpty {
                Text(String(localized: "No supported apps found", bundle: .agentPadResources))
                    .font(Theme.display(12.5, weight: .regular))
                    .foregroundStyle(Theme.chromeMuted)
                    .padding(.horizontal, Theme.space2 + 2)
                    .padding(.vertical, 8)
            } else {
                ForEach(visible) { app in
                    AgentPadMenuRow(title: app.title, localizesTitle: false) {
                        OpenInAppIcon(app: app, size: 16)
                    } action: {
                        isMenuOpen = false
                        if let dir { choose(app, dir: dir) }
                    }
                }
            }
        }
        .padding(Theme.space1)
        .frame(minWidth: 220)
        .background(Theme.chromeBackground)
    }

    /// Remember the app (so the split button's icon + plain-click target track
    /// the user's last choice) and open the directory in it. Saves imperatively
    /// rather than through the Settings `.onChange` autosave chain, because that
    /// chain is only mounted while the Settings window is open — this fires from
    /// the top-chrome button with Settings closed.
    private func choose(_ app: OpenInApp, dir: URL) {
        if model.lastOpenInAppId != app.id {
            model.lastOpenInAppId = app.id
            model.scheduleSave()
        }
        OpenInResolver.open(directory: dir, with: app)
    }

    private func openInLabel(for app: OpenInApp?) -> String {
        guard let app else {
            return String(localized: "Open in…", bundle: .agentPadResources)
        }
        return String.localizedStringWithFormat(
            String(localized: "Open in %@", bundle: .agentPadResources),
            app.title
        )
    }

    private var currentDirectory: URL? {
        let url = store.active?.activeSession?.currentDirectory ?? store.active?.workingDirectory
        return url?.standardizedFileURL
    }
}

/// Renders an `OpenInApp`'s real macOS icon (falls back to a generic app
/// glyph if the app went missing between resolution and render).
struct OpenInAppIcon: View {
    let app: OpenInApp
    let size: CGFloat

    var body: some View {
        if let icon = OpenInResolver.icon(for: app) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(Theme.chromeMuted)
        }
    }
}
