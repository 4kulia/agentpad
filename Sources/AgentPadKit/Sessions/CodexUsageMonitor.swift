import Foundation

/// Snapshot of a Codex account's rate-limit usage, parsed from the active
/// session's rollout JSONL. Codex writes a `token_count` event after every
/// turn carrying `rate_limits` (the 5-hour + weekly windows it enforces) plus
/// running token totals — AgentPad reads that line to drive the status-bar gauge.
/// All fields optional: an early rollout has token counts before the first
/// `rate_limits` block lands, and old rollouts predate some fields.
struct CodexUsage: Equatable {
    /// Shorter window — Codex's `primary` limit (`window_minutes: 300` = 5h).
    var primaryUsedPercent: Double?
    var primaryWindowMinutes: Int?
    var primaryResetsAt: Date?
    /// Longer window — Codex's `secondary` limit (`window_minutes: 10080` = 7d).
    var secondaryUsedPercent: Double?
    var secondaryWindowMinutes: Int?
    var secondaryResetsAt: Date?
    /// Subscription tier the limits belong to (`plus`, `pro`, …). Display-only.
    var planType: String?
    /// Current context-window occupancy: the last turn's total tokens
    /// (`last_token_usage.total_tokens` ≈ what's in the conversation now),
    /// which stays bounded near the window size — NOT the cumulative session
    /// total. Shown against `contextWindow` as used / total.
    var contextUsedTokens: Int?
    var contextWindow: Int?

    /// The gauge only makes sense once a window percentage exists; a
    /// tokens-only snapshot (no `rate_limits` yet) stays hidden.
    var hasQuota: Bool { primaryUsedPercent != nil || secondaryUsedPercent != nil }

    /// Every display field is present — walking further back in the rollout
    /// tail can't add anything, so the merge can stop early.
    var isComplete: Bool {
        primaryUsedPercent != nil && secondaryUsedPercent != nil
            && planType != nil && contextUsedTokens != nil && contextWindow != nil
    }

    /// Fills this snapshot's still-nil fields from an `older` one. Walking the
    /// tail newest-first, this keeps each field's newest non-nil value (a later
    /// line that omitted a block doesn't wipe what an earlier line carried).
    func filling(from older: CodexUsage) -> CodexUsage {
        var r = self
        r.primaryUsedPercent = r.primaryUsedPercent ?? older.primaryUsedPercent
        r.primaryWindowMinutes = r.primaryWindowMinutes ?? older.primaryWindowMinutes
        r.primaryResetsAt = r.primaryResetsAt ?? older.primaryResetsAt
        r.secondaryUsedPercent = r.secondaryUsedPercent ?? older.secondaryUsedPercent
        r.secondaryWindowMinutes = r.secondaryWindowMinutes ?? older.secondaryWindowMinutes
        r.secondaryResetsAt = r.secondaryResetsAt ?? older.secondaryResetsAt
        r.planType = r.planType ?? older.planType
        r.contextUsedTokens = r.contextUsedTokens ?? older.contextUsedTokens
        r.contextWindow = r.contextWindow ?? older.contextWindow
        return r
    }
}

/// Watches the active Codex session's rollout file and republishes its latest
/// `token_count` usage to `Session.codexUsage`. Codex blocks the shell while it
/// runs, so OSC 133 command-finished never fires mid-run — the only live
/// signal is the rollout file growing. A per-session `DispatchSource` file
/// watcher (mirrors `GitWatcher`) reads the tail on each append.
///
/// Locating the file: Codex names rollouts
/// `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`; the first line
/// is a `session_meta` record carrying the launch `cwd`. We match that against
/// the pane's cwd, and disambiguate a stale/concurrent Codex in the same
/// directory by *file identity*: we snapshot the rollouts that already exist
/// when the monitor first starts (before Codex has written its own ~10–15s
/// later) and adopt only the cwd-matching file that ISN'T in that snapshot —
/// this session's own. Codex can take 10–15s to write `session_meta` (auth +
/// model load first), so the resolve retries until that file appears.
/// Restored sessions are the inverse case: `codex resume` appends the existing
/// rollout, so we locate it by the persisted conversation UUID instead.
///
/// A single per-session generation counter guards every async hop (resolve,
/// debounced read, retry): each captures the counter and only commits if it's
/// still current, so `stop()` (tab close, cross-window move) cleanly aborts any
/// in-flight start/read/retry instead of letting it re-install a watcher or
/// publish onto a gone session.
@MainActor
final class CodexUsageMonitor {
    private struct Watch {
        let path: String
        let cwd: URL
        let sessionsRoot: URL
        let source: DispatchSourceFileSystemObject
        var pendingRead: DispatchWorkItem?
    }

    private var watches: [UUID: Watch] = [:]
    /// Monotonic per-session token, bumped on every `start`, debounced read, and
    /// `stop`. Each async hop captures it and commits only if still current —
    /// drops out-of-order reads AND aborts work for a session that was closed or
    /// re-resolved mid-flight (same generation-drop idea as `GitStatusFetcher`).
    private var generation: [UUID: Int] = [:]
    /// Rollout paths that already existed the first time this session's monitor
    /// started — captured before Codex wrote its own file. The session's own
    /// rollout is the one that appears *afterwards* and isn't in this set, so we
    /// adopt it by identity rather than a fragile launch-time comparison, and
    /// never mistake a prior/concurrent run's file for ours. Cleared on `stop`.
    private var preexisting: [UUID: Set<String>] = [:]
    /// A restored/moved Codex process resumes by appending its original rollout,
    /// so that file is intentionally inside `preexisting`. Preserve the exact
    /// conversation id supplied during initial wiring across later lifecycle
    /// `start` calls and retries; `stop` clears it before any fresh manual run.
    private var resumedConversationIds: [UUID: String] = [:]

    /// (Re)points the watcher for `sessionId` at this session's own rollout:
    /// either the exact pre-existing UUID being resumed, or the fresh
    /// cwd-matching file that did NOT pre-exist at first start. When that file
    /// doesn't exist yet (the launch → first-write race), it retries.
    ///
    /// The gauge reflects only THIS session's own quota readings — it appears
    /// once Codex writes the session's first `token_count` (after the first
    /// turn). We deliberately don't seed from a prior session's file: the
    /// rate-limit windows reset over time, so a days-old reading could show a
    /// stale percentage. Accuracy over immediacy.
    func start(
        sessionId: UUID,
        cwd: URL,
        sessionsRoot: URL,
        attempt: Int = 0,
        resumingConversationId: String? = nil,
        conversationUpdate: @MainActor @escaping (String) -> Void = { _ in },
        update: @MainActor @escaping (CodexUsage?) -> Void
    ) {
        // Snapshot once, on the first start — taken before Codex has written its
        // file (the first call is at tab spawn / the `running` event, both ahead
        // of codex's ~10–15s session_meta write). Reused across retries and the
        // later `running`-triggered start so this session's own file is never
        // accidentally captured into the exclusion set.
        if let id = resumingConversationId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            resumedConversationIds[sessionId] = id
        }
        // The exclusion snapshot only serves the fresh-session cwd probe;
        // a resume resolves by globally-unique conversation id and never
        // consults it — skip the directory enumeration entirely there.
        if preexisting[sessionId] == nil, resumedConversationIds[sessionId] == nil {
            preexisting[sessionId] = Self.recentRolloutPaths(under: sessionsRoot)
        }
        let exclude = preexisting[sessionId] ?? []
        let resumedConversationId = resumedConversationIds[sessionId]
        let token = (generation[sessionId] ?? 0) + 1
        generation[sessionId] = token
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let active = if let resumedConversationId {
                // Retries narrow to the last two day-directories —
                // re-walking the whole tree 30 times was the
                // accumulation-dependent launch cost.
                Self.resolveRollout(
                    conversationId: resumedConversationId,
                    sessionsRoot: sessionsRoot,
                    scope: attempt > 0 ? .recent(days: 2) : .full
                )
            } else {
                Self.resolveRollout(forCwd: cwd, sessionsRoot: sessionsRoot, excluding: exclude)
            }
            let seed = Self.currentUsage(activePath: active?.path)
            let conversationId = active.flatMap { Self.sessionMetaConversationId(atPath: $0.path) }
            DispatchQueue.main.async {
                // A stop() / newer start() bumped the generation while we
                // resolved — abort so this stale task can't re-install a watcher
                // or publish onto a closed / moved session.
                guard let self, self.generation[sessionId] == token else { return }
                if let conversationId { conversationUpdate(conversationId) }
                if let seed { update(seed) }
                guard let active else {
                    // Rollout not created yet. Codex can take 10–15s after launch
                    // to write session_meta (auth + model load happen first), so
                    // retry for ~30s — too short and we give up before this
                    // session's own file exists and never attach the live watch.
                    // The retry re-checks the generation so a stop() cancels it.
                    guard attempt < 30 else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, self.generation[sessionId] == token else { return }
                        self.start(sessionId: sessionId, cwd: cwd, sessionsRoot: sessionsRoot,
                                   attempt: attempt + 1,
                                   resumingConversationId: resumedConversationId,
                                   conversationUpdate: conversationUpdate,
                                   update: update)
                    }
                    return
                }
                if self.watches[sessionId]?.path != active.path {
                    self.install(sessionId: sessionId, path: active.path, cwd: cwd,
                                 sessionsRoot: sessionsRoot, update: update)
                }
                self.scheduleRead(sessionId: sessionId, update: update)
            }
        }
    }

    func stop(sessionId: UUID) {
        // Never started for this session — don't materialize state, so the
        // unconditional stop() in onCommandFinished is a true no-op for plain
        // shells.
        guard watches[sessionId] != nil || generation[sessionId] != nil else { return }
        generation[sessionId] = (generation[sessionId] ?? 0) + 1  // invalidate in-flight start / read / retry
        preexisting[sessionId] = nil
        resumedConversationIds[sessionId] = nil
        if let watch = watches.removeValue(forKey: sessionId) {
            watch.pendingRead?.cancel()
            watch.source.cancel()
        }
    }

    func stopAll() {
        for id in Array(watches.keys) { stop(sessionId: id) }
    }

    private func install(
        sessionId: UUID,
        path: String,
        cwd: URL,
        sessionsRoot: URL,
        update: @MainActor @escaping (CodexUsage?) -> Void
    ) {
        // Replace any existing watcher for this session (relaunch → new file).
        if let existing = watches.removeValue(forKey: sessionId) {
            existing.pendingRead?.cancel()
            existing.source.cancel()
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = source.data
            if data.contains(.delete) || data.contains(.rename) {
                // The watched file was unlinked/replaced (rotation, or the user
                // cleared ~/.codex). The fd is now dead and won't fire again —
                // tear it down (closes the fd via the cancel handler) and
                // re-resolve from the cwd so a new rollout is picked up without
                // waiting for the next lifecycle event.
                self.stop(sessionId: sessionId)
                self.start(sessionId: sessionId, cwd: cwd, sessionsRoot: sessionsRoot, update: update)
                return
            }
            self.scheduleRead(sessionId: sessionId, update: update)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watches[sessionId] = Watch(path: path, cwd: cwd, sessionsRoot: sessionsRoot,
                                   source: source, pendingRead: nil)
    }

    /// Debounced tail read — Codex can append several lines per turn; coalesce
    /// into one parse ~200ms after the burst settles (matches `GitWatcher`).
    private func scheduleRead(
        sessionId: UUID,
        update: @MainActor @escaping (CodexUsage?) -> Void
    ) {
        guard var watch = watches[sessionId] else { return }
        watch.pendingRead?.cancel()
        let path = watch.path
        let token = (generation[sessionId] ?? 0) + 1
        generation[sessionId] = token
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let usage = Self.currentUsage(activePath: path)
                DispatchQueue.main.async {
                    // Drop a slow read that a newer one (or a stop) superseded,
                    // so an out-of-order completion can't overwrite fresher data
                    // or publish onto a closed session.
                    guard let self, self.generation[sessionId] == token else { return }
                    update(usage)
                }
            }
        }
        watch.pendingRead = work
        watches[sessionId] = watch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: - Rollout location (pure, background-safe)

    /// The Codex `sessions/` root, honoring a `CODEX_HOME` the user exported in
    /// their shell rc. A Dock/Finder-launched AgentPad doesn't inherit that in its
    /// own `ProcessInfo`, but the `codex` child does (and writes rollouts under
    /// it), so we read the live shell env first — otherwise we'd scan the wrong
    /// `~/.codex` and the gauge would never appear.
    nonisolated static func sessionsRoot(shellEnv: [String: String]) -> URL {
        let raw = shellEnv["CODEX_HOME"] ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
        let home = raw.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("sessions")
    }

    nonisolated static func defaultSessionsRoot() -> URL {
        sessionsRoot(shellEnv: [:])
    }

    /// Rollout files in the last few day-partitioned dirs, newest mtime first.
    /// The active session's file is written *now*, so today/yesterday cover it
    /// (incl. a run crossing midnight) without stat-ing years of history.
    nonisolated static func recentRollouts(under sessionsRoot: URL, days: Int = 3) -> [URL] {
        let fm = FileManager.default
        var candidates: [(url: URL, mtime: Date)] = []
        for dir in recentDayDirectories(under: sessionsRoot, days: days) {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                candidates.append((url, mtime))
            }
        }
        return candidates.sorted(by: { $0.mtime > $1.mtime }).map(\.url)
    }

    /// The rollout file paths in the recent day-dirs — a snapshot of what
    /// pre-existed at launch. Uses the same `contentsOfDirectory(at:)`
    /// enumeration as `recentRollouts` so the path strings match exactly (that
    /// API resolves symlinks like `/var`→`/private/var`; a hand-joined path
    /// wouldn't, and the exclusion `Set` lookup would silently miss).
    nonisolated static func recentRolloutPaths(under sessionsRoot: URL) -> Set<String> {
        let fm = FileManager.default
        var paths = Set<String>()
        for dir in recentDayDirectories(under: sessionsRoot, days: 3) {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
                paths.insert(url.path)
            }
        }
        return paths
    }

    /// Newest rollout whose `session_meta` cwd matches `cwd` and that is NOT in
    /// `excluding` — i.e. *this* session's own file, which appeared after the
    /// launch snapshot. A rollout that pre-existed belongs to an earlier (or
    /// concurrent) run, so it's skipped even during the launch race when this
    /// session's own file doesn't exist yet — that's what keeps the gauge from
    /// flashing a prior session's usage on a fresh tab.
    nonisolated static func resolveRollout(
        forCwd cwd: URL,
        sessionsRoot: URL = CodexUsageMonitor.defaultSessionsRoot(),
        excluding: Set<String> = []
    ) -> URL? {
        let target = cwd.standardizedFileURL.resolvingSymlinksInPath().path
        for url in recentRollouts(under: sessionsRoot) {
            if excluding.contains(url.path) { continue }  // pre-existed at launch → another run
            guard let metaCwd = sessionMetaCwd(atPath: url.path) else { continue }
            if URL(fileURLWithPath: metaCwd).standardizedFileURL.resolvingSymlinksInPath().path == target {
                return url
            }
        }
        return nil
    }

    /// Where a by-id rollout lookup is allowed to search.
    enum RolloutSearchScope: Equatable, Sendable {
        /// 30-day shallow probe, then the full recursive walk — first
        /// attempts, where the conversation may be months old.
        case full
        /// Only the last N day-directories, no deep fallback — the retry
        /// loop's increment-only mode: the first attempt covered history,
        /// and a file APPEARING between retries can only land in today's
        /// (or, at midnight, yesterday's) partition.
        case recent(days: Int)
    }

    /// A resumed Codex appends the rollout that already existed before this
    /// AgentPad process launched. Match that file by its globally unique session
    /// id instead of applying the fresh-launch exclusion snapshot.
    /// Lookup is layered: most resumes target a recent conversation, so probe
    /// recent day-directories with shallow filename-only listings first, and
    /// only a months-old conversation pays the full recursive walk.
    nonisolated static func resolveRollout(
        conversationId: String,
        sessionsRoot: URL = CodexUsageMonitor.defaultSessionsRoot(),
        scope: RolloutSearchScope = .full
    ) -> URL? {
        let target = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        // Codex includes the session UUID at the end of every rollout
        // filename, so directory listings match on the name alone and only
        // the single suffix match pays a file read.
        let suffix = "-\(target).jsonl"
        let fm = FileManager.default
        let probeDays: Int
        switch scope {
        case .full: probeDays = 30
        case .recent(let days): probeDays = days
        }
        for dir in recentDayDirectories(under: sessionsRoot, days: probeDays) {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for url in files
            where url.lastPathComponent.hasPrefix("rollout-") && url.lastPathComponent.hasSuffix(suffix) {
                if sessionMetaConversationId(atPath: url.path) == target { return url }
            }
        }
        guard scope == .full else { return nil }
        guard let enumerator = fm.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.lastPathComponent.hasSuffix(suffix),
                  sessionMetaConversationId(atPath: url.path) == target
            else { continue }
            return url
        }
        return nil
    }

    /// The value to publish for a session: this session's own latest quota
    /// reading, or nil until its rollout carries one. Only ever this session's
    /// data — never a sibling session's (which could be stale). Used for both
    /// the initial read and every watch read.
    nonisolated static func currentUsage(activePath: String?) -> CodexUsage? {
        guard let activePath, let usage = latestUsage(atPath: activePath), usage.hasQuota else {
            return nil
        }
        return usage
    }

    /// The `<sessions>/YYYY/MM/DD` directories for the last `days` days. Built
    /// from the calendar rather than enumerated so a deep history stays cheap.
    nonisolated static func recentDayDirectories(under sessions: URL, days: Int) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var dirs: [URL] = []
        for offset in 0..<max(days, 1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            // Codex partitions rollouts as YYYY/MM/DD (zero-padded).
            let y = String(format: "%04d", c.year ?? 0)
            let m = String(format: "%02d", c.month ?? 0)
            let d = String(format: "%02d", c.day ?? 0)
            dirs.append(sessions.appendingPathComponent(y).appendingPathComponent(m).appendingPathComponent(d))
        }
        return dirs
    }

    /// Reads the first line (the `session_meta` record) and returns
    /// `payload.cwd`. Reads up to the first newline rather than a fixed chunk:
    /// `session_meta` embeds `base_instructions`, which can push the line past
    /// any fixed size — and a truncated chunk is invalid JSON that would never
    /// match, silently disabling the gauge for that session.
    nonisolated static func sessionMetaCwd(atPath path: String) -> String? {
        sessionMetaPayload(atPath: path).flatMap(cwd(fromSessionMetaPayload:))
    }

    nonisolated static func cwd(fromSessionMetaPayload payload: [String: Any]) -> String? {
        payload["cwd"] as? String
    }

    /// Codex writes both `id` and (on current builds) `session_id` in the
    /// first session_meta payload. Prefer the documented/session-facing `id`
    /// but retain the older key as a compatibility fallback.
    nonisolated static func sessionMetaConversationId(atPath path: String) -> String? {
        sessionMetaPayload(atPath: path).flatMap(conversationId(fromSessionMetaPayload:))
    }

    nonisolated static func conversationId(fromSessionMetaPayload payload: [String: Any]) -> String? {
        for key in ["id", "session_id"] {
            guard let raw = payload[key] as? String else { continue }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { return id }
        }
        return nil
    }

    /// `internal` (not private): the session-history scanner reads id + cwd
    /// from ONE payload parse instead of paying the newline-bounded read
    /// twice per rollout.
    nonisolated static func sessionMetaPayload(atPath path: String) -> [String: Any]? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var data = Data()
        let newline = UInt8(0x0A)
        while data.count < 4 * 1024 * 1024 {  // safety cap against a missing newline
            guard let chunk = try? fh.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            data.append(chunk)
            if let nl = data.firstIndex(of: newline) {
                data = data.prefix(upTo: nl)
                break
            }
        }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = obj["payload"] as? [String: Any]
        else { return nil }
        return payload
    }

    // MARK: - Usage parsing (pure, background-safe)

    /// Reads the tail of the rollout and returns the merged latest usage.
    nonisolated static func latestUsage(atPath path: String) -> CodexUsage? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        let start = size > window ? size - window : 0
        // Always rewind from the end-of-file offset `seekToEnd` left us at —
        // even for a small file (`start == 0`), or `readToEnd` reads nothing.
        try? fh.seek(toOffset: start)
        let data = (try? fh.readToEnd()) ?? Data()
        return latestUsage(inTail: String(decoding: data, as: UTF8.self), droppingPartialHead: start > 0)
    }

    /// Merges the `token_count` lines in `tail`, keeping each field's newest
    /// non-nil value (a later line that omits a block — a null `rate_limits`,
    /// or a window without a `used_percent` — doesn't wipe what an earlier line
    /// carried). Walks newest-first and stops as soon as every field is filled,
    /// so the common case (the last line carries everything) parses one line
    /// instead of the whole 256 KB tail. When the tail was cut mid-file, the
    /// first (partial) line is dropped.
    nonisolated static func latestUsage(inTail tail: String, droppingPartialHead: Bool) -> CodexUsage? {
        var lines = tail.split(whereSeparator: \.isNewline)
        if droppingPartialHead, !lines.isEmpty { lines.removeFirst() }

        var result: CodexUsage?
        for line in lines.reversed() {
            guard let fields = parseTokenCountLine(String(line)) else { continue }
            result = result?.filling(from: fields) ?? fields
            if result?.isComplete == true { break }
        }
        return result
    }

    /// Parses one rollout line; returns a `CodexUsage` only for a
    /// `token_count` event, else nil.
    nonisolated static func parseTokenCountLine(_ line: String) -> CodexUsage? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            (obj["type"] as? String) == "event_msg",
            let payload = obj["payload"] as? [String: Any],
            (payload["type"] as? String) == "token_count"
        else { return nil }

        var usage = CodexUsage()
        if let info = payload["info"] as? [String: Any] {
            if let last = info["last_token_usage"] as? [String: Any],
               let lastTotal = last["total_tokens"] as? Int {
                usage.contextUsedTokens = lastTotal
            }
            usage.contextWindow = info["model_context_window"] as? Int
        }
        if let limits = payload["rate_limits"] as? [String: Any] {
            usage.planType = limits["plan_type"] as? String
            if let primary = limits["primary"] as? [String: Any] {
                usage.primaryUsedPercent = numeric(primary["used_percent"])
                usage.primaryWindowMinutes = primary["window_minutes"] as? Int
                usage.primaryResetsAt = epoch(primary["resets_at"])
            }
            if let secondary = limits["secondary"] as? [String: Any] {
                usage.secondaryUsedPercent = numeric(secondary["used_percent"])
                usage.secondaryWindowMinutes = secondary["window_minutes"] as? Int
                usage.secondaryResetsAt = epoch(secondary["resets_at"])
            }
        }
        // A line with neither context info nor quota isn't worth surfacing.
        return (usage.hasQuota || usage.contextUsedTokens != nil || usage.contextWindow != nil) ? usage : nil
    }

    /// JSON numbers decode to `Int` or `Double` depending on the literal
    /// (`8` vs `8.0`); accept both for percentages.
    nonisolated private static func numeric(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    nonisolated private static func epoch(_ value: Any?) -> Date? {
        guard let seconds = numeric(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
