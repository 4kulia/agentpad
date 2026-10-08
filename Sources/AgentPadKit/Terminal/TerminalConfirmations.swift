import AppKit
import SwiftUI

@MainActor
enum ClipboardConfirmPresenter {
    @MainActor
    enum Kind {
        case unsafePaste
        case oscRead
        case oscWrite

        var statusLabel: String {
            switch self {
            case .unsafePaste: String(localized: "UNSAFE-PASTE", bundle: .agentPadResources)
            case .oscRead, .oscWrite: String(localized: "CLIPBOARD-ACCESS", bundle: .agentPadResources)
            }
        }

        var headline: String {
            switch self {
            case .unsafePaste: String(localized: "Paste looks dangerous", bundle: .agentPadResources)
            case .oscRead: String(localized: "Allow clipboard read?", bundle: .agentPadResources)
            case .oscWrite: String(localized: "Allow clipboard write?", bundle: .agentPadResources)
            }
        }

        var subtitle: String {
            switch self {
            case .unsafePaste:
                String(localized: "The clipboard text contains characters that may run commands the moment they are pasted.", bundle: .agentPadResources)
            case .oscRead:
                String(localized: "A program running in the terminal wants to read your clipboard.", bundle: .agentPadResources)
            case .oscWrite:
                String(localized: "A program running in the terminal wants to replace your clipboard contents.", bundle: .agentPadResources)
            }
        }

        var allowTitle: String {
            switch self {
            case .unsafePaste: String(localized: "paste anyway", bundle: .agentPadResources)
            case .oscRead, .oscWrite: String(localized: "allow", bundle: .agentPadResources)
            }
        }
    }


    private static let pendingByWindow = NSMapTable<NSWindow, ConfirmationCoordinator>.weakToWeakObjects()

    static func present(on window: NSWindow, session: Session, kind: Kind, contents: String,
                        deadline: Date = Date().addingTimeInterval(120),
                        stillValid: @escaping () -> Bool, onDecision: @escaping (Bool) -> Void) {
        let c = session.terminalConfirmation
        guard pendingByWindow.object(forKey: window) == nil, !c.showsBlock,
              c.canShow(), stillValid() else { onDecision(false); return }
        session.clipboardPreview = contents
        pendingByWindow.setObject(c, forKey: window)
        c.request(.init(tabID: session.id, targetID: "clipboard", deadline: deadline, callerWaiting: true),
            title: kind.headline, consequences: kind.subtitle, verb: kind.allowTitle, stillValid: stillValid,
            completion: { [weak window, weak session] accepted in
                if let window { pendingByWindow.removeObject(forKey: window) }
                session?.clipboardPreview = nil
                onDecision(accepted)
            }, operation: {})
    }
}

@MainActor
enum ConfirmCloseTab {
    enum Outcome: Equatable { case closed, presenting, confirming, windowBusy }

    @discardableResult
    static func request(_ session: Session, in workspace: Workspace, store: WorkspaceStore,
                        anchorWindow: NSWindow? = nil, willPresent: (() -> Void)? = nil,
                        callerWaiting: (() -> Bool)? = nil) -> Outcome {
        guard callerWaiting?() != false else { return .windowBusy }
        guard session.engine.needsConfirmQuit else {
            store.closeTab(session, in: workspace); return .closed
        }
        guard let window = session.engine.view.window ?? anchorWindow, window.attachedSheet == nil else { return .windowBusy }
        let c = session.terminalConfirmation
        if c.showsBlock {
            guard c.isAwaiting, c.context?.targetID == "close" else { return .windowBusy }
            return c.isVisible ? .confirming : .presenting
        }
        guard !store.allSessions.contains(where: { $0.terminalConfirmation.showsBlock }) else { return .windowBusy }
        willPresent?()
        store.activateWorkspace(workspace); store.activateTab(session, in: workspace)
        // Activation updates AppKit visibility on the next render. Keep the
        // request in the session now; shown/confirm still require a visible host.
        let pid = session.engine.foregroundPid
        let start = pid.flatMap { ProcessInfoReader.info(of: $0)?.startTime }
        guard pid == nil || start != nil else { return .windowBusy }
        let accepted = c.request(.init(tabID: session.id, targetID: "close", revision: start.map(String.init(describing:)), callerWaiting: callerWaiting != nil),
            title: "Close “\(session.title)”?", consequences: "A process is still running in this tab; closing will terminate it.",
            verb: "Close tab", destructive: true, stillValid: { [weak store, weak session] in
                guard callerWaiting?() != false, let store, let session, store.location(ofSessionId: session.id) != nil,
                      session.engine.foregroundPid == pid else { return false }
                return pid.map { ProcessInfoReader.info(of: $0)?.startTime == start } ?? true
            }, operation: { [weak store, weak session] in
                guard let store, let session, let current = store.location(ofSessionId: session.id) else { return }
                store.closeTab(session, in: current.workspace)
            })
        return accepted ? .presenting : .windowBusy
    }

    /// SwiftUI mounts the block on the next update. The CLI acknowledges only
    /// that observed presentation; a detached/hidden host never grants a close.
    static func waitForPresentation(_ session: Session, store: WorkspaceStore,
                                    timeout: Duration = .seconds(1)) async -> Outcome {
        let c = session.terminalConfirmation, id = c.context?.actionID
        let until = ContinuousClock.now.advanced(by: timeout)
        while c.context?.actionID == id, c.isAwaiting, !c.isVisible, ContinuousClock.now < until, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
            c.validate()
        }
        if c.phase == .completed, store.location(ofSessionId: session.id) == nil { return .closed }
        guard c.context?.actionID == id else { return .windowBusy }
        if c.isVisible, c.canShow(), c.isAwaiting || c.isExecuting { return .confirming }
        c.invalidate()
        return .windowBusy
    }
}

@MainActor
enum TerminalProcessActions {
    static func requestKill(_ process: SessionProcess, session: Session,
                            matches: @escaping (pid_t, UInt64) -> Bool = SessionProcessScanner.identityMatches,
                            signal: @escaping (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) }) {
        session.terminalConfirmation.request(.init(tabID: session.id, targetID: "process:\(process.pid)",
            revision: String(process.startedAtUs)), title: "Stop process \(process.pid)?",
            consequences: "Send SIGTERM to \(process.name). Unsaved work in this process may be lost.", verb: "Stop process", destructive: true,
            stillValid: { matches(process.pid, process.startedAtUs) }, operation: {
                guard matches(process.pid, process.startedAtUs) else { throw ProcessOperationError("The process changed. No signal was sent.") }
                guard signal(process.pid, SIGTERM) == 0 else { throw ProcessOperationError(String(cString: strerror(errno))) }
            })
    }
}

struct TerminalConfirmation: View {
    let session: Session
    var body: some View {
        InlineConfirmation(coordinator: session.terminalConfirmation) {
            if let contents = session.clipboardPreview {
                ScrollView { Text(String(contents.prefix(4096))).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 120)
                if contents.count > 4096 { Text("Preview: first 4,096 characters of \(contents.count).") .font(.caption) }
            }
        }
    }
}

struct ProcessOperationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
