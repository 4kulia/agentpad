import AppKit
import SwiftUI

/// One native host per Session. Moving/remounting keeps this view and its state;
/// no terminal factory, start, monitors or process authorization are involved.
@MainActor
final class NativeTabEngine: TerminalEngine {
    static var content: (TabState) -> AnyView = { state in
        AnyView(VStack(spacing: 12) {
            Image(systemName: state.route.symbol).font(.largeTitle)
            Text(state.route.title).font(.title2)
            Text(state.message ?? "This screen is not available in this version.").foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity))
    }
    let state: TabState
    weak var owner: WorkspaceStore?
    let tabID: TabID
    private(set) var starts = 0
    private(set) var terminations = 0
    private lazy var host = NSHostingView(rootView: NativeTabRoot(engine: self))
    init(state: TabState, tabID: TabID) { self.state = state; self.tabID = tabID }
    var view: NSView { host }
    weak var rememberedFocus: NSView?
    func rememberFocus() {
        if let responder = host.window?.firstResponder as? NSView, responder.isDescendant(of: host) { rememberedFocus = responder }
    }
    func focus() {
        guard let owner, owner.active?.activeSession?.id == tabID, let window = host.window,
              window.isKeyWindow, !host.isHiddenOrHasHiddenAncestor else { return }
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: host) { return }
        if let rememberedFocus, rememberedFocus.window === window { window.makeFirstResponder(rememberedFocus) }
        else { window.makeFirstResponder(nil); window.selectNextKeyView(host) }
    }
    func renderNowIfNeeded() {}
    func setOnScreen(_ onScreen: Bool) { if !onScreen { state.leave() } }
    var backgroundColor: NSColor { .windowBackgroundColor }
    var onPwdChange: ((String) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onCommandFinished: ((Int?, TimeInterval) -> Void)?
    var onUserInput: (() -> Void)?
    var onSearchStart: ((String) -> Void)?
    var onSearchEnd: (() -> Void)?
    var onSearchTotal: ((Int) -> Void)?
    var onSearchSelected: ((Int) -> Void)?
    var pasteUploadHostProvider: (() -> String?)?
    var isRemoteSessionProvider: (() -> Bool)?
    var foregroundPid: pid_t? { nil }
    var onProcessExitedCleanly: (() -> Void)?
    var onDesktopNotification: ((String, String) -> Void)?
    var onLinkHover: ((String?) -> Void)?
    var needsConfirmQuit: Bool { false }
    func start(config: TerminalSessionConfig) { starts += 1 }
    func terminate() { terminations += 1; state.close() }
    var suspendsSizePropagation: Bool { false }
    func beginSizePropagationSuspension() {}
    func endSizePropagationSuspension() {}
    func flushSize() {}
    var grabsFocusOnMount = false
    var spawnsWhileHidden = false
    @discardableResult func performAction(_ name: String) -> Bool { false }
    func sendInput(_ text: String) {}
    func paste(_ text: String) {}
    func pasteFromClipboardViaCore() -> Bool { false }
    func readSelection() -> String? { nil }
}

private struct NativeTabRoot: View {
    let engine: NativeTabEngine
    var body: some View {
        VStack(spacing: 0) {
            NativeTabEngine.content(engine.state)
            if let error = engine.state.saveError {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Changes could not be saved").font(.headline)
                    Text(error).foregroundStyle(.red)
                    ViewThatFits(in: .horizontal) {
                        HStack { recovery }
                        VStack(alignment: .leading) { recovery }
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("tab-save-error")
            }
            if engine.state.canShowConfirmation() {
                InlineConfirmation(coordinator: engine.state.confirmation).padding(.horizontal, 16)
            }
        }
        .foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tool-tab-" + engine.tabID.uuidString)
    }
    @ViewBuilder private var recovery: some View {
        Button("Keep editing") { engine.owner?.tabCloseCoordinator.keepEditing(engine.tabID); engine.state.saveError = nil }
        Button("Retry") {
            if engine.owner?.tabCloseCoordinator.hasPending(engine.tabID) == true { engine.owner?.tabCloseCoordinator.retry(engine.tabID) }
            else { engine.owner?.flushPersistence() }
        }
        Button("Discard local changes", role: .destructive) {
            if engine.owner?.tabCloseCoordinator.hasPending(engine.tabID) == true { engine.owner?.tabCloseCoordinator.discard(engine.tabID) }
            else { engine.owner?.tabCloseCoordinator.discardEdits(engine.state) }
        }
        .disabled(engine.state.localForm?.working == true || engine.state.publicationForm?.working == true)
    }
}
