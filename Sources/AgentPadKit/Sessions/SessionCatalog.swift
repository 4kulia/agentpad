import Foundation
import GRDB
import Observation

struct SessionHeaderCache: Codable {
    // Version 1 could cache I/O failures as non-sessions. Discard those entries.
    static let parseVersion = 2
    struct Fingerprint: Codable, Equatable {
        var inode: UInt64
        var size: Int64
        var seconds: Int64
        var nanoseconds: Int64
        init?(file: URL) {
            var value = stat()
            guard stat(file.path, &value) == 0 else { return nil }
            inode = UInt64(value.st_ino); size = Int64(value.st_size)
            seconds = Int64(value.st_mtimespec.tv_sec); nanoseconds = Int64(value.st_mtimespec.tv_nsec)
        }
    }
    struct Header: Codable { var fingerprint: Fingerprint; var record: AgentSessionRecord? }
    enum CodingKeys: String, CodingKey { case parseVersion = "parse_version", headers }
    var parseVersion = Self.parseVersion
    var headers: [String: Header] = [:]

    static func load(_ url: URL) -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        if let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode(Self.self, from: data),
           cache.parseVersion == parseVersion { return cache }
        // Disposable metadata only. Never shares a recovery path with session-names.sqlite.
        try? FileManager.default.removeItem(at: url)
        return Self()
    }
}

enum SessionCatalogScanner {
    struct Progress: Sendable {
        var records: [AgentSessionRecord]
        var scanned: Int
        var total: Int
        var skipped: Int
        /// Only records added since the previous progress callback. nil keeps
        /// injected/legacy scanners compatible; the profile store also dedupes.
        var discoveredRecords: [AgentSessionRecord]? = nil
    }
    /// Read-only even in offline mode; personal calls are automatic, channel calls excluded by their own policy.
    static func automaticConversations(journalURL: URL) -> Set<String> {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return [] }
        do {
            var configuration = Configuration(); configuration.readonly = true
            let queue = try DatabaseQueue(path: journalURL.path, configuration: configuration)
            return try queue.read { Set(try String.fetchAll($0, sql: "SELECT DISTINCT conversation_id FROM runs WHERE kind != 'channel'")) }
        } catch { return [] }
    }

    static func scan(roots: [String: URL], cacheURL: URL, visibility: ChannelConversationFilter,
                     automatic: Set<String> = [],
                     onRead: @Sendable (URL) -> Void = { _ in },
                     collect: @Sendable (AgentSessionScanner.Store, URL) -> [AgentSessionRecord] = { $0.collect($1) },
                     progress: @Sendable (Progress) -> Void = { _ in }) -> Progress {
        let old = SessionHeaderCache.load(cacheURL)
        var cache = SessionHeaderCache(), records: [String: AgentSessionRecord] = [:]
        var discovered: [AgentSessionRecord] = []
        func include(_ record: AgentSessionRecord) {
            var record = record
            if automatic.contains(record.conversationId) { record.automatic = true }
            records[record.id] = record
            discovered.append(record)
        }
        var files: [(agent: String, file: URL, date: Date)] = []
        for store in AgentSessionScanner.stores {
            guard let root = roots[store.agentId] else { continue }
            if store.agentId == AgentTemplate.claudeCodeID {
                files += AgentSessionScanner.claudeSessionFiles(under: root).filter {
                    visibility.allows(conversationId: $0.item.deletingPathExtension().lastPathComponent, root: root)
                }.map { (store.agentId, $0.item, $0.mtime) }
            } else if store.agentId == AgentTemplate.codex.id {
                files += AgentSessionScanner.codexRolloutFiles(under: root).map { (store.agentId, $0.item, $0.mtime) }
            } else {
                // SQLite queries always run, regardless of the main file's mtime (WAL).
                for record in visibility.apply(collect(store, root)) {
                    if records[record.id].map({ $0.lastActivity >= record.lastActivity }) != true { include(record) }
                }
            }
        }
        files.sort { $0.date != $1.date ? $0.date > $1.date : $0.file.path < $1.file.path }
        var skipped = 0
        func snapshot(_ scanned: Int) -> Progress {
            let ordered = records.values.sorted { $0.lastActivity != $1.lastActivity ? $0.lastActivity > $1.lastActivity : $0.id < $1.id }
            defer { discovered.removeAll(keepingCapacity: true) }
            return Progress(records: ordered, scanned: scanned, total: files.count, skipped: skipped, discoveredRecords: discovered)
        }
        progress(snapshot(0))
        for (index, entry) in files.enumerated() {
            if Task.isCancelled { return snapshot(index) }
            guard let fingerprint = SessionHeaderCache.Fingerprint(file: entry.file) else { skipped += 1; continue }
            let header: SessionHeaderCache.Header
            if let cached = old.headers[entry.file.path], cached.fingerprint == fingerprint { header = cached }
            else {
                onRead(entry.file)
                do {
                    let record = try entry.agent == AgentTemplate.claudeCodeID
                        ? AgentSessionScanner.readClaudeRecord(file: entry.file, mtime: entry.date)
                        : AgentSessionScanner.readCodexRecord(file: entry.file, mtime: entry.date)
                    header = .init(fingerprint: fingerprint, record: record)
                } catch {
                    // Keep no fingerprint on failure: an unchanged file must be
                    // retried on Rescan once permissions or transient I/O recover.
                    skipped += 1
                    continue
                }
            }
            cache.headers[entry.file.path] = header
            if let record = header.record, visibility.allows(agentId: record.agentId, conversationId: record.conversationId,
                                                           startedAt: record.startedAt, root: roots[record.agentId]!) {
                if records[record.id] == nil { include(record) }
            } else { skipped += 1 }
            if (index + 1).isMultiple(of: 50) { progress(snapshot(index + 1)) }
        }
        if let bytes = try? JSONEncoder().encode(cache) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? bytes.write(to: cacheURL, options: .atomic)
        }
        return snapshot(files.count)
    }
}

@MainActor @Observable
final class SessionCatalog {
    static let shared = SessionCatalog(profiles: .shared) { progress in
        SessionCatalogScanner.scan(roots: Dictionary(uniqueKeysWithValues: AgentSessionScanner.stores.map { ($0.agentId, $0.defaultRoot()) }),
            cacheURL: SessionCatalogFiles.directory.appendingPathComponent("session-headers.json"), visibility: .current(),
            automatic: SessionCatalogScanner.automaticConversations(journalURL: ChatFiles.standard.journalURL), progress: progress)
    }
    typealias Scan = @Sendable (@escaping @Sendable (SessionCatalogScanner.Progress) -> Void) -> SessionCatalogScanner.Progress
    @ObservationIgnored private let scan: Scan
    @ObservationIgnored private(set) var records: [AgentSessionRecord] = []
    @ObservationIgnored private var recordKeys: Set<SessionNameKey> = []
    private(set) var revision = 0
    private(set) var isScanning = false
    private(set) var scanned = 0
    private(set) var total = 0
    private(set) var skipped = 0
    private var lastScan: Date?
    private var scanID = UUID()
    @ObservationIgnored private var deferred: Task<Void, Never>?
    @ObservationIgnored private let profiles: AgentProfileStore?
    init(profiles: AgentProfileStore? = nil, scan: @escaping Scan) { self.profiles = profiles; self.scan = scan }

    func refresh(force: Bool = false) {
        guard !isScanning else { schedule(); return }
        if !force, let lastScan, Date().timeIntervalSince(lastScan) < 30 { schedule(); return }
        deferred?.cancel(); deferred = nil
        isScanning = true; scanned = 0
        scanID = UUID(); let id = scanID
        let scan = scan
        Task {
            let (updates, continuation) = AsyncStream<SessionCatalogScanner.Progress>.makeStream()
            Task.detached(priority: .utility) {
                let result = scan { continuation.yield($0) }
                continuation.yield(result); continuation.finish()
            }
            // Preserve callback order: dropping a progress snapshot would now
            // also drop its discovery increment.
            for await update in updates {
                guard scanID == id else { return }
                apply(update)
            }
            isScanning = false; lastScan = Date()
        }
    }
    func count(including live: [AllSessionItem]) -> Int {
        _ = revision
        return records.count + live.count - Set(live.filter(\.canRename).map { $0.record.nameKey }).intersection(recordKeys).count
    }
    private func apply(_ update: SessionCatalogScanner.Progress) {
        do { try profiles?.discover(update.discoveredRecords ?? update.records) } catch { /* Profiles expose discovery/save errors. */ }
        recordKeys = Set(update.records.map(\.nameKey))
        records = update.records; scanned = update.scanned; total = update.total; skipped = update.skipped; revision += 1
    }
    private func schedule() {
        guard deferred == nil else { return }
        deferred = Task { [weak self] in
            guard let self else { return }
            let delay = max(1, 30 - Date().timeIntervalSince(lastScan ?? Date()))
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            deferred = nil; refresh()
        }
    }
}

enum SessionPreview {
    struct Message: Identifiable, Equatable, Sendable {
        var id: Int
        var role: String
        var text: String
    }
    /// Bounded tail, read on demand and never indexed or persisted by AgentPad.
    static func read(_ record: AgentSessionRecord) -> [Message] {
        guard [AgentTemplate.claudeCodeID, AgentTemplate.codex.id].contains(record.agentId), let file = record.fileURL,
              let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > 262_144 ? size - 262_144 : 0
        guard (try? handle.seek(toOffset: start)) != nil, let bytes = try? handle.read(upToCount: 262_144) else { return [] }
        var lines = Array(bytes.split(separator: 10)); if start > 0 && !lines.isEmpty { lines.removeFirst() }
        var messages: [Message] = []
        for (index, line) in lines.enumerated() {
            guard let object = AgentSessionScanner.jsonObject(line) else { continue }
            var role: String?, text: String?
            if record.agentId == AgentTemplate.claudeCodeID {
                role = object["type"] as? String
                if let message = object["message"] as? [String: Any] {
                    text = message["content"] as? String ?? (message["content"] as? [[String: Any]])?
                        .filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
            } else if object["type"] as? String == "response_item", let payload = object["payload"] as? [String: Any], payload["type"] as? String == "message" {
                role = payload["role"] as? String
                text = (payload["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            guard let role, ["user", "assistant"].contains(role), let text = SessionTitle.nonempty(text) else { continue }
            if role == "user", AgentSessionScanner.displayableUserText(text) == nil { continue }
            messages.append(.init(id: index, role: role, text: text))
        }
        return Array(messages.suffix(3))
    }
}
