import AppKit
import Foundation
import Observation

/// Live list of Claude Code sessions running OUTSIDE this app — the other half
/// of "every session in one window". `AgentMonitor` already covers our own
/// tabs; this covers Terminal.app, iTerm2 and friends.
///
/// Polls rather than watches: Claude Code rewrites each session file in place,
/// which a directory watcher doesn't see, and reading ~30 tiny files every
/// 1.5s is cheaper than any watcher bookkeeping.
@MainActor
@Observable
final class ExternalSessionMonitor {
    static let shared = ExternalSessionMonitor()

    private(set) var sessions: [ExternalAgentSession] = []
    /// Set while a takeover is in flight, so the row can show progress and
    /// can't be clicked twice.
    private(set) var takingOver: Set<String> = []

    static let pollInterval: Duration = .milliseconds(1500)
    /// Titles come from transcripts; re-read them at most this often per session.
    static let titleRefreshInterval: TimeInterval = 60

    /// Called on the main actor after every refresh, changed or not.
    var onRefresh: (([ExternalAgentSession]) -> Void)?
    /// Called when listed sessions are gone (exited, or moved here).
    var onSessionsEnded: (([ExternalAgentSession]) -> Void)?
    /// AgentPad: Claude Code's own status for sessions running in OUR tabs,
    /// which the list above leaves out. Lets a tab's hook-driven state be
    /// checked against Claude's (`WorkspaceStore.reconcileWithClaudeStatus`).
    var onOwnSessions: (([ExternalAgentSession]) -> Void)?

    private var pollTask: Task<Void, Never>?
    private var titleCache: [String: TitleCacheEntry] = [:]

    private struct TitleCacheEntry {
        var parts = ExternalSessionParser.TitleParts()
        var offset: UInt64 = 0
        var readAt: Date
    }

    /// Injectable for tests: how a raw snapshot is produced.
    var snapshotProvider: @Sendable () async -> [ExternalAgentSession] = {
        await Task.detached(priority: .utility) {
            ExternalSessionSource.readSessionFiles() ?? ExternalSessionSource.runAgentsCommand() ?? []
        }.value
    }
    var conversationVisibility: () -> ChannelConversationFilter = { .current() }

    init() {}

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        let raw = await snapshotProvider()
        let visibility = conversationVisibility()
        titleCache = titleCache.filter { visibility.allows(conversationId: $0.key) }
        let ownPid = getpid()
        var result: [ExternalAgentSession] = []
        var own: [ExternalAgentSession] = []
        for var session in raw {
            guard visibility.allows(conversationId: session.sessionId) else { continue }
            // Session files outlive crashed processes; only keep the ones whose
            // PID still is that session's claude.
            guard let info = processInfo(session.pid),
                  ProcessInfoReader.matchesClaudeSession(info, startedAt: session.startedAt)
            else { continue }
            // Sessions in our own tabs are already listed by AgentMonitor.
            if ProcessInfoReader.ancestors(of: session.pid).contains(ownPid) {
                own.append(session)
                continue
            }
            session.tty = info.tty
            session.processStart = info.startTime
            session.title = cachedTitle(for: session.sessionId)
            result.append(session)
        }
        // A session file is rewritten in place, so one poll can catch it
        // half-written and drop it. Keep the last good row while its exact
        // process is still alive, instead of flickering (and re-notifying).
        let seen = Set(result.map(\.id))
        for previous in sessions where !seen.contains(previous.id) && visibility.allows(conversationId: previous.sessionId) {
            if let start = previous.processStart, processInfo(previous.pid)?.startTime == start,
               !raw.contains(where: { $0.pid == previous.pid }) {
                result.append(previous)
            }
        }
        let ended = sessions.filter { old in !result.contains { $0.id == old.id } }
        result.sort(by: Self.order)
        if result != sessions { sessions = result }
        if !ended.isEmpty { onSessionsEnded?(ended) }
        refreshStaleTitles(for: result)
        onRefresh?(sessions)
        onOwnSessions?(own)
    }

    /// Neediest first, then the longest-waiting / most recently active.
    static func order(_ a: ExternalAgentSession, _ b: ExternalAgentSession) -> Bool {
        if a.monitorState != b.monitorState { return a.monitorState < b.monitorState }
        let aSince = a.statusSince ?? .distantPast
        let bSince = b.statusSince ?? .distantPast
        if a.monitorState == .attention { return aSince < bSince }
        if aSince != bSince { return aSince > bSince }
        return a.sessionId < b.sessionId
    }

    /// Injectable for tests: process lookup by PID.
    var processInfo: (pid_t) -> ProcessInfoReader.Info? = { ProcessInfoReader.info(of: $0) }

    private func cachedTitle(for sessionId: String) -> String? {
        titleCache[sessionId]?.parts.best
    }

    private func refreshStaleTitles(for sessions: [ExternalAgentSession]) {
        let now = Date()
        let stale = sessions.map(\.sessionId).filter { id in
            guard let cached = titleCache[id] else { return true }
            return now.timeIntervalSince(cached.readAt) > Self.titleRefreshInterval
        }
        guard !stale.isEmpty else { return }
        // Mark as read up front so a slow transcript read isn't re-queued by the next poll.
        var requests: [(String, UInt64)] = []
        for id in stale {
            var entry = titleCache[id] ?? TitleCacheEntry(readAt: now)
            entry.readAt = now
            titleCache[id] = entry
            requests.append((id, entry.offset))
        }
        Task.detached(priority: .utility) { [weak self] in
            let titles = requests.map { id, offset in (id, ExternalSessionSource.titleParts(for: id, after: offset)) }
            await self?.applyTitles(titles)
        }
    }

    private func applyTitles(_ titles: [(String, (parts: ExternalSessionParser.TitleParts, offset: UInt64, isFullRead: Bool)?)]) {
        let visibility = conversationVisibility()
        var changed = false
        for (id, read) in titles {
            guard visibility.allows(conversationId: id), let read, var entry = titleCache[id] else { continue }
            let previous = entry.parts
            // Incremental reads only ever see newer lines, so they override;
            // a full re-read (file rewritten) replaces outright.
            entry.parts = read.isFullRead ? read.parts : previous.updated(with: read.parts)
            entry.offset = read.offset
            titleCache[id] = entry
            if entry.parts != previous { changed = true }
        }
        guard changed else { return }
        sessions = sessions.map { session in
            var copy = session
            copy.title = titleCache[session.sessionId]?.parts.best
            return copy
        }
    }

    // MARK: Actions

    enum TakeOverError: Error, Equatable {
        case notIdle
        case stillRunning
        /// The process is gone or is no longer the session we listed.
        case changed
        case noTranscript
        case resumeRefused(String)
    }

    /// Ends the session in its terminal and resumes the same conversation in a
    /// new tab here. The conversation is on disk, so nothing is lost; whatever
    /// that terminal tab was running in the background is.
    func takeOver(_ session: ExternalAgentSession, into store: WorkspaceStore) async -> Result<Void, TakeOverError> {
        guard session.canTakeOver, let expectedStart = session.processStart else { return .failure(.notIdle) }
        guard !takingOver.contains(session.id) else { return .failure(.stillRunning) }
        takingOver.insert(session.id)
        defer { takingOver.remove(session.id) }

        // Everything below is checked against FRESH state: the row was
        // captured before the confirmation dialog, and the user may have
        // typed into that terminal while it was open.
        // Ask before killing anything: a refusal after SIGTERM would leave the
        // user with neither the old session nor a new one.
        if let refusal = WorkspaceStore.resumeRefusal(
            agentId: AgentTemplate.claudeCodeID, conversationId: session.sessionId,
            visibility: conversationVisibility(), claudeProjectsRoot: store.claudeProjectsRoot
        ) {
            return .failure(.resumeRefused(Self.message(refusal, session)))
        }
        let root = store.claudeProjectsRoot
        let visibility = conversationVisibility()
        guard await Task.detached(priority: .userInitiated, operation: {
            ExternalSessionSource.transcript(for: session.sessionId, under: root, visibility: visibility) != nil
        }).value else {
            return .failure(.noTranscript)
        }
        // The last await. From the fresh status check to the signal below
        // everything is synchronous, so the user can't slip a prompt in between.
        let snapshot = await snapshotProvider()
        if let refusal = WorkspaceStore.resumeRefusal(
            agentId: AgentTemplate.claudeCodeID, conversationId: session.sessionId,
            visibility: conversationVisibility(), claudeProjectsRoot: root
        ) {
            return .failure(.resumeRefused(Self.message(refusal, session)))
        }
        guard let fresh = snapshot.first(where: { $0.pid == session.pid && $0.sessionId == session.sessionId }) else {
            return .failure(.changed)
        }
        guard fresh.status == .idle else { return .failure(.notIdle) }
        // Same process instance as the one we listed, checked right before
        // the signal so a recycled PID is never hit.
        guard let info = processInfo(session.pid),
              info.startTime == expectedStart,
              ProcessInfoReader.matchesClaudeSession(info, startedAt: session.startedAt)
        else {
            return .failure(.changed)
        }

        kill(session.pid, SIGTERM)
        let exited = await Self.waitForExit(session.pid, startTime: expectedStart, timeout: .seconds(6))
        guard exited else { return .failure(.stillRunning) }

        switch store.resumeAgentSession(
            agentId: AgentTemplate.claudeCodeID,
            conversationId: session.sessionId,
            cwd: session.cwd
        ) {
        case .success:
            sessions.removeAll { $0.pid == session.pid }
            return .success(())
        case .failure(let refusal):
            return .failure(.resumeRefused(Self.message(refusal, session)))
        }
    }

    private static func message(_ refusal: WorkspaceStore.ResumeRefusal, _ session: ExternalAgentSession) -> String {
        refusal.message(agentId: AgentTemplate.claudeCodeID, conversationId: session.sessionId)
    }

    /// True once that process INSTANCE is gone — a new process reusing the
    /// PID counts as gone.
    static func waitForExit(_ pid: pid_t, startTime: TimeInterval, timeout: Duration) async -> Bool {
        func gone() -> Bool { ProcessInfoReader.info(of: pid)?.startTime != startTime }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if gone() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return gone()
    }
}
