import AppKit
import SwiftUI

/// AppKit workspace-persistence shell — the C2 hybrid boundary.
///
/// **AppKit owns "which workspace is visible"; SwiftUI owns everything inside
/// a workspace.** One `PaneTreeHostView` per window (owned by
/// `AgentPadWindowController`, mounted through a stable representable) keeps one
/// `WorkspaceRootView` per workspace alive for the workspace's whole lifetime
/// and flips visibility on switches. That alone kills the old
/// `.id(workspace.id)` teardown class (focus races on switch / issue #24,
/// detach-gap scale bugs / issue #8, switch flicker) — while the split tree,
/// pane chrome, zoom and divider animations inside each container stay the
/// battle-tested SwiftUI implementation with its own coordinated layout
/// (`WorkspaceSplitRoot`). A fully AppKit-owned pane tree was tried first
/// (v0.50) and reverted: five attempts could not reproduce SwiftUI's
/// compositor-coordinated zoom smoothness, and the workspace boundary is
/// where AppKit ownership actually pays.
///
/// The reconciler pattern survives at this level: `renderNow()` reads the
/// workspace list + active ids inside `withObservationTracking`, syncs
/// containers, and re-arms. `syncFocus` stays the keyboard authority for
/// workspace SWITCHES (nothing re-mounts on a switch anymore, so the old
/// mount-time grab can't fire); within a workspace the restored SwiftUI tree
/// keeps its original mount-grab + click-gesture focus paths.

/// Shared base for the host's containers: top-left origin and re-layout on
/// any own-frame change.
@MainActor
class FlippedLayoutView: NSView {
    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
}

@MainActor
final class PaneTreeHostView: FlippedLayoutView {
    private let store: WorkspaceStore
    private var workspaceViews: [UUID: WorkspaceRootView] = [:]
    private var renderScheduled = false

    /// What terminal focus should track: the active tab of the active pane of
    /// the active workspace. Focus is only re-asserted when this key changes —
    /// an unrelated reconcile must never steal the caret from a composer /
    /// search field.
    private struct FocusKey: Equatable {
        var workspaceId: UUID?
        var paneId: UUID?
        var tabId: UUID?
    }
    private var lastFocusKey: FocusKey?

    init(store: WorkspaceStore) {
        self.store = store
        super.init(frame: .zero)
        clipsToBounds = true
        renderNow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func layout() {
        super.layout()
        // Only the active workspace tracks our bounds; hidden ones keep stale
        // frames (their engines must not receive per-resize SIGWINCHes while
        // invisible) and re-sync at activation via the reconcile-set
        // `needsLayout`.
        if let activeId = store.active?.id, let view = workspaceViews[activeId] {
            if view.frame != bounds { view.frame = bounds }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Initial focus: the host is built before the window exists, so the
        // first reconcile couldn't hand the keyboard to the active terminal.
        if window != nil { syncFocus(force: true) }
    }

    /// Coalesce any number of observation change notifications into one
    /// reconcile pass on the next main-queue turn (observation fires at
    /// willSet — views must only be mutated after the store settles).
    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.renderNow()
        }
    }

    /// One reconcile pass. Internal (not private) so tests can drive the
    /// host synchronously instead of pumping the run loop.
    func renderNow() {
        renderScheduled = false
        withObservationTracking {
            reconcile()
        } onChange: { [weak self] in
            // Every observable the reconciler reads is @MainActor, so willSet
            // lands on main by construction — assume (trapping loudly if that
            // ever changes) and schedule on THIS turn's queue drain.
            MainActor.assumeIsolated { self?.scheduleRender() }
        }
    }

    /// Explicit navigation back into the active tab uses the same overlay
    /// guards and native-editor restoration as an ordinary tab switch.
    func restoreFocus() { syncFocus(force: true) }

    private func reconcile() {
        let workspaces = store.workspaces
        let activeId = store.active?.id

        var seen = Set<UUID>()
        for workspace in workspaces {
            seen.insert(workspace.id)
            let view: WorkspaceRootView
            if let existing = workspaceViews[workspace.id] {
                view = existing
            } else {
                view = WorkspaceRootView(workspace: workspace, store: store)
                workspaceViews[workspace.id] = view
                addSubview(view)
                // A workspace created while the app runs (⌘N / sidebar +) is
                // born ACTIVE, so its container never passes the hidden-flip
                // branch below — and in a real display cycle `addSubview`
                // does NOT dirty the superview, so nothing would ever assign
                // the new container a frame: the fresh workspace rendered
                // blank until the next window resize (issue #52). The manual
                // `layoutSubtreeIfNeeded()` in tests happens to re-layout the
                // host in the no-window xctest environment, which is why the
                // container tests stayed green while the app was broken.
                needsLayout = true
            }
            let isActive = workspace.id == activeId
            if view.isHidden == isActive {
                view.isHidden = !isActive
                if isActive {
                    // Frames were left stale while hidden; the layout pass
                    // re-syncs before display.
                    needsLayout = true
                    view.needsLayout = true
                }
            }
        }
        for (id, view) in workspaceViews where !seen.contains(id) {
            view.removeFromSuperview()
            workspaceViews[id] = nil
        }

        syncFocus(force: false)
    }

    /// Keyboard authority for switches. A workspace switch re-mounts nothing
    /// (containers just flip visibility), so no mount-time grab fires — this
    /// is the single place that hands the revealed workspace's active
    /// terminal the keyboard. Within a workspace the SwiftUI tree's own
    /// paths (mount grab on new tabs/splits, click gestures) do the work;
    /// this then mostly agrees with them (same target) or no-ops.
    private func syncFocus(force: Bool) {
        let workspace = store.active
        let pane = workspace?.activePane
        let key = FocusKey(
            workspaceId: workspace?.id,
            paneId: pane?.id,
            tabId: pane?.activeTab?.id
        )
        let changed = key != lastFocusKey
        lastFocusKey = key
        guard changed || force else { return }
        guard let window else { return }
        guard let session = pane?.activeTab else {
            // Empty splits are focusable too: never keep typing into the
            // previously selected terminal while an empty pane is active.
            if let responder = window.firstResponder as? NSView,
               workspaceViews.values.contains(where: { responder.isDescendant(of: $0) }) {
                window.makeFirstResponder(nil)
            }
            return
        }
        // An open composer / search bar owns the keyboard in the destination
        // pane. Surviving editors re-claim focus themselves (`PaneComposerBar` /
        // `PaneSearchBar` observe their pane becoming active) — stealing
        // for the terminal here would put the caret in the shell UNDER a
        // visible editor, where Return executes a command (Codex P1).
        if session.composerActive || session.searchActive { return }
        if let native = session.engine as? NativeTabEngine { native.focus(); return }
        let target = session.engine.view
        // The freshly-activated tab's view may not be mounted yet (SwiftUI
        // applies the swap on its own schedule) — its mount-time grab owns
        // that case.
        guard target.window === window else { return }
        // Other panes may still have open editors in this workspace. Only
        // the destination's editor guard above may keep the caret from its terminal.
        window.makeFirstResponder(target)
    }

    // MARK: - Test hooks

    func workspaceRootView(for id: UUID) -> WorkspaceRootView? { workspaceViews[id] }
}

/// One workspace's persistent container: a plain AppKit shell holding the
/// SwiftUI split tree (`WorkspaceSplitRoot`) for the workspace's lifetime.
/// Hidden while inactive — `isHidden` skips drawing and, through the
/// engine-side `viewDidHide`/`viewDidUnhide` gating, pauses every terminal's
/// render link, while the SwiftUI tree stays mounted so a switch back is
/// pure reveal.
@MainActor
final class WorkspaceRootView: FlippedLayoutView {
    let workspace: Workspace
    private let hosting: NSHostingView<WorkspaceSplitRoot>

    init(workspace: Workspace, store: WorkspaceStore) {
        self.workspace = workspace
        hosting = NSHostingView(rootView: WorkspaceSplitRoot(workspace: workspace, store: store))
        super.init(frame: .zero)
        // Frame-managed by layout(); SwiftUI must not fight it with
        // intrinsic-size constraints.
        hosting.sizingOptions = []
        clipsToBounds = true
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func layout() {
        super.layout()
        if hosting.frame != bounds { hosting.frame = bounds }
    }
}

/// SwiftUI bridge for the host — one stable representable per window; the
/// NSView identity is owned by `AgentPadWindowController`, so SwiftUI structure
/// changes around it can never tear the workspace containers down.
struct PaneTreeHostRepresentable: NSViewRepresentable {
    let host: PaneTreeHostView

    func makeNSView(context: Context) -> PaneTreeHostView { host }
    func updateNSView(_ nsView: PaneTreeHostView, context: Context) {}
}
