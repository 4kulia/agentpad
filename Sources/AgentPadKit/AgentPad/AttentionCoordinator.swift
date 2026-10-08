import AppKit
import Foundation

/// Everything about "which sessions need you", across our own tabs and other
/// terminals: the Dock badge, banners for external sessions, and the
/// "next session needing you" jump.
@MainActor
final class AttentionCoordinator {
    static let shared = AttentionCoordinator()

    var notificationManager: NotificationManager?
    var navigation: NotificationNavigation?
    var terminalFocused: (UUID) -> Bool = { _ in false }
    var terminalExists: (UUID) -> Bool = { _ in false }
    private var refreshTask: Task<Void, Never>?
    var observedScopes: Set<AttentionScope> = []
    var refreshing = false
    var sourcesReady = false
    /// Focus one of our own tabs (wired to the same reveal path notifications use).
    var activateOwn: (UUID) -> Void = { _ in }

    /// "<row id>|<status since>" of every waiting episode already seen. Nil
    /// until the first refresh, so launching the app doesn't banner every
    /// session that was already waiting; keyed by episode so a row that
    /// flickers out and back can't banner twice for the same wait.
    private var seenWaitingEpisodes: Set<String>?
    private var lastHistoryRefresh = Date.distantPast
    private var pendingHistoryRefresh: Task<Void, Never>?

    /// At most one rescan per 10s, but never dropped: a request inside the
    /// window (or during a running scan) is deferred, not discarded.
    private func scheduleHistoryRefresh() {
        guard pendingHistoryRefresh == nil else { return }
        pendingHistoryRefresh = Task { @MainActor [weak self] in
            guard let self else { return }
            let wait = max(0, 10 - Date().timeIntervalSince(self.lastHistoryRefresh))
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            while AgentSessionHistory.shared.isScanning {
                try? await Task.sleep(for: .seconds(1))
            }
            self.lastHistoryRefresh = Date()
            self.pendingHistoryRefresh = nil
            AgentSessionHistory.shared.refresh(force: true)
        }
    }
    /// The waiting item the jump went to last, so repeated presses cycle.
    private var lastJumpId: String?

    init() {}

    func start() {
        let ledger = AttentionLedger.shared
        ledger.delivery = notificationManager
        ledger.preferences = { AgentPadSettingsModel.shared.notificationPreferences }
        ledger.isFocused = { [weak self] in self?.focused($0) ?? false }
        ledger.isValid = { [weak self] in self?.valid($0) ?? false }
        ledger.onChange = { [weak self] in self?.refreshBadge() }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshSources()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        ExternalSessionMonitor.shared.onRefresh = { [weak self] sessions in
            self?.externalSessionsRefreshed(sessions)
        }
        // A conversation that just ended belongs under "recent" now; the
        // history scan only runs on demand, so nudge it (at most every 10s).
        ExternalSessionMonitor.shared.onSessionsEnded = { [weak self] _ in
            self?.scheduleHistoryRefresh()
        }
    }

    // MARK: Waiting list

    enum Target: Equatable {
        case own(UUID)
        case external(String)

        var key: String {
            switch self {
            case .own(let id): return "own:\(id.uuidString)"
            case .external(let id): return "ext:\(id)"
            }
        }
    }

    /// Our own waiting tabs first (in AgentMonitor's order), then external
    /// ones, longest-waiting first. External targets are keyed by process
    /// (`ExternalAgentSession.id`): two processes can share a conversation.
    static func waitingTargets(own: [AgentMonitor.Entry], external: [ExternalAgentSession]) -> [Target] {
        let mine: [Target] = own.filter { $0.state == .attention }.map { .own($0.id) }
        let theirs: [Target] = external.filter { $0.monitorState == .attention }.map { .external($0.id) }
        return mine + theirs
    }

    /// The target after `last` in `targets`, wrapping; the first one when
    /// `last` is nil or no longer waiting.
    static func next(after last: String?, in targets: [Target]) -> Target? {
        guard !targets.isEmpty else { return nil }
        guard let last, let index = targets.firstIndex(where: { $0.key == last }) else { return targets[0] }
        return targets[(index + 1) % targets.count]
    }

    private var currentTargets: [Target] {
        Self.waitingTargets(own: AgentMonitor.shared.entries, external: ExternalSessionMonitor.shared.sessions)
    }

    /// ⌘⇧U. Returns false when nothing is waiting.
    @discardableResult
    func jumpToNextWaiting() -> Bool {
        guard let target = Self.next(after: lastJumpId, in: currentTargets) else {
            NSSound.beep()
            return false
        }
        lastJumpId = target.key
        activate(target)
        return true
    }

    func activate(_ target: Target) {
        switch target {
        case .own(let id):
            activateOwn(id)
        case .external(let id):
            if let session = ExternalSessionMonitor.shared.sessions.first(where: { $0.id == id }) {
                ExternalSessionActions.focus(session)
            }
        }
    }

    // MARK: Refresh

    static func episodeKey(_ session: ExternalAgentSession) -> String {
        "\(session.id)|\(session.statusSince?.timeIntervalSince1970 ?? 0)"
    }

    private func externalSessionsRefreshed(_ sessions: [ExternalAgentSession]) {
        let waiting = sessions.filter { $0.monitorState == .attention }
        let keys = Set(waiting.map(Self.episodeKey))
        let first = seenWaitingEpisodes == nil
        for session in waiting {
            var event = AttentionEvent(source: "external", object: session.id, episode: Self.episodeKey(session),
                                       kind: .input, destination: .external(session.id))
            event.isRead = first
            if first { AttentionLedger.shared.metadata.update(event.id) { $0.delivered = true } }
            AttentionLedger.shared.upsert(event)
        }
        let ids = Set(waiting.map { AttentionEvent(source: "external", object: $0.id, episode: Self.episodeKey($0), kind: .input, destination: .external($0.id)).id })
        AttentionLedger.shared.reconcile(source: "external", keeping: ids)
        seenWaitingEpisodes = keys
        refreshBadge()
    }

    /// AgentPad: recount now, e.g. when a team call waits for a decision.
    func refreshBadge() { updateBadge(external: ExternalSessionMonitor.shared.sessions) }

    private func updateBadge(external: [ExternalAgentSession]) {
        let count = AttentionLedger.shared.pendingCount + ChatNotifications.mentionsForBadge()
        let label = count > 0 ? "\(count)" : nil
        if NSApp?.dockTile.badgeLabel != label { NSApp?.dockTile.badgeLabel = label }
    }
}
