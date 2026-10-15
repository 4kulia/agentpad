import AgentPadHookKit
import AgentPadTelegram
import Darwin
import Foundation

/// One FIFO, including provider suspensions. Actor isolation alone is not enough.
actor SidebarFoldersStore {
    enum Operation: Sendable {
        case load(defaults: [String])
        case defaults([String])
        case attach((any TelegramChatProvider)?, TelegramProfileBinding?)
        case recover
        case refreshTelegram
        case create(UUID, name: String, symbol: String)
        case createAndAdd(UUID, name: String, symbol: String, item: SidebarItemReference)
        case rename(UUID, name: String, symbol: String)
        case delete(UUID)
        case member(UUID, SidebarItemReference, Bool)
        case move(String, Int)
        case visible(String, Bool)
        case telegramVisible(TelegramListKey, Bool)
        case telegramCollapsed(UUID, TelegramListKey, Bool)
        case windows(Set<UUID>)
        case viewport([UUID:Range<Int>])
    }
    static var standardURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(AppIdentity.supportDirectoryName)/sidebar-folders.json")
    }
    private let url: URL
    private let write: @Sendable (Data,URL) throws -> Void
    private let timeout: Duration
    // Every input to publish shares one dirty revision, including mutations
    // completed before a later provider/disk failure. Repeated refreshes are cheap.
    private var stateRevision: UInt64 = 0
    private var publishedRevision: UInt64?
    private var catalog = SidebarFolderCatalog() {
        didSet { if catalog != oldValue { stateRevision &+= 1 } }
    }
    private var provider: (any TelegramChatProvider)?
    private var binding: TelegramProfileBinding? {
        didSet { if binding != oldValue { stateRevision &+= 1 } }
    }
    private var telegramMembers: [UUID:Set<Int64>] = [:] {
        didSet { if telegramMembers != oldValue { stateRevision &+= 1 } }
    }
    private var summaries: [SidebarItemReference:SidebarItemSummary] = [:] {
        didSet { stateRevision &+= 1 }
    }
    private var sortedRows: [UUID:[SidebarItemSummary]] = [:]
    private var viewports: [UUID:Range<Int>] = [:] {
        didSet { if viewports != oldValue { stateRevision &+= 1 } }
    }
    private var snapshot = SidebarFoldersSnapshot()
    private struct Pending {
        let operation: Operation
        let binding: TelegramProfileBinding?
        let continuation: CheckedContinuation<SidebarFolderResult,Never>
    }
    private var pending: [Pending] = []
    private var running = false
    private var observers: [UUID:AsyncStream<SidebarFoldersSnapshot>.Continuation] = [:]

    init(url: URL = SidebarFoldersStore.standardURL, timeout: Duration = .seconds(10),
         write: @escaping @Sendable (Data,URL) throws -> Void = SidebarFoldersDisk.write) {
        self.url = url; self.timeout = timeout; self.write = write
    }
    func current() -> SidebarFoldersSnapshot { snapshot }
    var queuedOperationCount: Int { pending.count }
    func snapshots() -> AsyncStream<SidebarFoldersSnapshot> {
        let id = UUID(), pair = AsyncStream<SidebarFoldersSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = pair.continuation; pair.continuation.yield(snapshot)
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return pair.stream
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    /// Pass the originating snapshot's binding, captured before scheduling the
    /// action. Neither enqueue nor execution may substitute the current profile.
    func perform(_ operation: Operation, binding origin: TelegramProfileBinding?) async -> SidebarFolderResult {
        await withCheckedContinuation { continuation in
            pending.append(Pending(operation: operation, binding: origin, continuation: continuation))
            if !running { running = true; Task { await drain() } }
        }
    }
    private func drain() async {
        while !pending.isEmpty {
            let entry = pending.removeFirst()
            do { try await execute(entry.operation, binding: entry.binding); entry.continuation.resume(returning: .success) }
            catch {
                let failure: SidebarFolderFailure
                if let error = error as? SidebarFolderFailure { failure = error }
                else if let error = error as? TelegramFolderError {
                    failure = switch error { case .staleBinding: .staleBinding; case .unavailable: .unavailable; case .tooLarge: .tooLarge; case .invalidTarget: .invalid; case .storage: .storage }
                } else { failure = .storage }
                entry.continuation.resume(returning: .failure(failure))
            }
        }
        running = false
    }
    private func call<T: Sendable>(binding origin: TelegramProfileBinding?, _ body: @escaping @Sendable (any TelegramChatProvider,TelegramProfileBinding) async throws -> T) async throws -> T {
        guard origin == binding else { throw SidebarFolderFailure.staleBinding }
        guard let provider, let origin else { throw SidebarFolderFailure.unavailable }
        return try await SidebarProviderDeadline.run(timeout: timeout) { try await body(provider,origin) }
    }
    private func save(_ candidate: SidebarFolderCatalog) throws {
        try candidate.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try write(encoder.encode(candidate),url)
        catalog = candidate; publish()
    }
    private func execute(_ operation: Operation, binding origin: TelegramProfileBinding?) async throws {
        defer { publish() }
        // Reject before any catalog side effects, including create-and-add and
        // delete. Lifecycle load/attach instead reconcile their selected profile.
        switch operation {
        case .recover, .refreshTelegram, .createAndAdd, .delete, .member, .telegramVisible, .telegramCollapsed, .windows:
            guard origin == binding else { throw SidebarFolderFailure.staleBinding }
        default: break
        }
        switch operation {
        case .load(let defaults):
            var candidate = SidebarFolderCatalog()
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    candidate = try JSONDecoder().decode(SidebarFolderCatalog.self, from: Data(contentsOf: url))
                    try candidate.validate()
                } catch {
                    // Preserve the entire damaged file. A failed rename must not overwrite it.
                    let backup = url.deletingLastPathComponent().appendingPathComponent("sidebar-folders.corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json")
                    try FileManager.default.moveItem(at: url, to: backup)
                    candidate = SidebarFolderCatalog()
                }
            }
            candidate.addDefaults(defaults); try save(candidate)
            if provider != nil, binding != nil { try await recover(binding: binding) }
        case .defaults(let entries):
            var candidate = catalog; candidate.addDefaults(entries)
            if candidate != catalog { try save(candidate) }
        case .attach(let provider, let binding):
            if self.binding != binding {
                telegramMembers = [:]; summaries = summaries.filter { if case .telegram = $0.key { false } else { true } }
            }
            self.provider = provider; self.binding = binding; publish()
            if provider != nil, binding != nil { try await recover(binding: binding) }
        case .recover: try await recover(binding: origin)
        case .refreshTelegram: try await refreshTelegram(binding: origin)
        case .create(let id, let name, let symbol): try create(id, name: name, symbol: symbol)
        case .createAndAdd(let id, let name, let symbol, let item):
            try create(id, name: name, symbol: symbol)
            try await member(id, item: item, present: true, binding: origin)
        case .rename(let id, let name, let symbol):
            guard let index = catalog.custom.firstIndex(where: { $0.id == id }) else { throw SidebarFolderFailure.deleted }
            var candidate = catalog; candidate.custom[index].name = name; candidate.custom[index].symbol = symbol; try save(candidate)
        case .delete(let id):
            var candidate = catalog
            candidate.tombstones.insert(id); candidate.custom.removeAll { $0.id == id }
            candidate.order.removeAll { $0 == SidebarEntryIdentity.custom(id) }; candidate.hidden.remove(SidebarEntryIdentity.custom(id))
            try save(candidate)
            // Unavailability is deferred work, durably represented by the tombstone.
            if provider != nil, origin != nil {
                try await call(binding: origin) { try await $0.applyTombstones([id], binding: $1) }
                telegramMembers[id] = nil; publish()
            }
        case .member(let id, let item, let present): try await member(id, item: item, present: present, binding: origin)
        case .move(let id, let destination):
            guard let old = catalog.order.firstIndex(of: id) else { throw SidebarFolderFailure.invalid }
            var candidate = catalog; candidate.order.remove(at: old)
            candidate.order.insert(id, at: min(candidate.order.count,max(0,destination))); try save(candidate)
        case .visible(let id, let visible):
            guard SidebarEntryIdentity.persistable(id, allowTelegramBlock: false) else { throw SidebarFolderFailure.invalid }
            var candidate = catalog
            if visible { candidate.hidden.remove(id) } else { candidate.hidden.insert(id) }
            try save(candidate)
        case .telegramVisible(let list, let visible): try await call(binding: origin) { try await $0.setListVisible(list, visible: visible, binding: $1) }
        case .telegramCollapsed(let window, let list, let collapsed): try await call(binding: origin) { try await $0.setListCollapsed(window: window, list: list, collapsed: collapsed, binding: $1) }
        case .windows(let windows): try await call(binding: origin) { try await $0.retainFolderWindows(windows, binding: $1) }
        case .viewport(let windows):
            guard windows.values.allSatisfy({ $0.lowerBound >= 0 && $0.count <= 76 }),
                  windows.values.reduce(0, { $0 + $1.count }) <= 76 else { throw SidebarFolderFailure.tooLarge }
            viewports = windows; publish()
        }
    }
    private func create(_ id: UUID, name: String, symbol: String) throws {
        guard !catalog.tombstones.contains(id) else { throw SidebarFolderFailure.deleted }
        guard !catalog.custom.contains(where: { $0.id == id }) else { return }
        var candidate = catalog; candidate.custom.append(.init(id: id, name: name, symbol: symbol))
        candidate.order.insert(SidebarEntryIdentity.custom(id), at: 0); try save(candidate)
    }
    private func recover(binding origin: TelegramProfileBinding?) async throws {
        let tombstones = catalog.tombstones
        try await call(binding: origin) { try await $0.applyTombstones(tombstones, binding: $1) }
        let members = try await call(binding: origin) { try await $0.customMembers(binding: $1) }
        var candidate = catalog
        for id in members.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !candidate.tombstones.contains(id) && !candidate.custom.contains(where: { $0.id == id }) {
            let pins = id == origin?.migratedPinsID
            candidate.custom.append(.init(id: id, name: pins ? "Pinned here" : "Recovered folder", symbol: pins ? "bookmark" : "folder"))
            candidate.order.insert(SidebarEntryIdentity.custom(id), at: candidate.order.firstIndex(of: "telegram") ?? candidate.order.count)
        }
        try save(candidate); telegramMembers = members
        try await refreshTelegram(binding: origin)
    }
    private func member(_ id: UUID, item: SidebarItemReference, present: Bool, binding origin: TelegramProfileBinding?) async throws {
        guard let index = catalog.custom.firstIndex(where: { $0.id == id }), !catalog.tombstones.contains(id) else { throw SidebarFolderFailure.deleted }
        if provider != nil, origin != nil { telegramMembers = try await call(binding: origin) { try await $0.customMembers(binding: $1) } }
        let exists: Bool
        switch item {
        case .telegram(let chat): exists = telegramMembers[id]?.contains(chat) == true
        case .agentpad(let item): exists = catalog.custom[index].items.contains(item)
        }
        if present, !exists {
            let local = catalog.custom.reduce(0) { $0 + $1.items.count }, remote = telegramMembers.values.reduce(0) { $0 + $1.count }
            guard catalog.custom[index].items.count + (telegramMembers[id]?.count ?? 0) < 20_000,
                  local + remote < 100_000 else { throw SidebarFolderFailure.tooLarge }
        }
        var candidate = catalog
        switch item {
        case .telegram(let chat):
            try await call(binding: origin) { try await $0.setCustomMember(folder: id, chat: chat, member: present, binding: $1) }
            if present { telegramMembers[id,default: []].insert(chat) } else { telegramMembers[id]?.remove(chat) }
        case .agentpad(let reference):
            candidate.custom[index].items.removeAll { $0 == reference }
            if present { candidate.custom[index].items.append(reference) }
        }
        try save(candidate)
    }
    /// One summary per unique reference. Only changed member sets/summaries sort again.
    func updateTelegramRows(_ rows: [TelegramChatRow], binding: TelegramProfileBinding?) {
        guard let binding, self.binding == binding else { return }
        let members = Set(telegramMembers.values.flatMap { $0 })
        let unique = Dictionary(rows.filter { $0.id.environment == binding.environment && $0.id.account == binding.account && members.contains($0.id.chat) }.map { ($0.id,$0) },uniquingKeysWith: { first,_ in first })
        mergeSummaries(unique.values.map(SidebarItemSummary.telegram))
    }
    /// AgentPad metadata has no Telegram binding. Telegram metadata enters only
    /// through updateTelegramRows, which rejects late results after reconnection.
    func updateSummaries(_ values: [SidebarItemSummary]) {
        mergeSummaries(values.filter { if case .agentpad = $0.reference { true } else { false } })
    }
    private func mergeSummaries(_ values: [SidebarItemSummary]) {
        for value in values where summaries[value.reference] != value {
            summaries[value.reference] = value
        }
        publish()
    }
    private func refreshTelegram(binding origin: TelegramProfileBinding?) async throws {
        let values = try await call(binding: origin) { try await $0.customSummaries(binding: $1) }
        // Missing metadata is unavailability, never removal of membership.
        let known = Set(values.map(\.chat))
        let missing = Set(telegramMembers.values.flatMap { $0 }).subtracting(known).map { chat in
            SidebarItemSummary(reference: .telegram(chat), title: "Unavailable", activity: nil, available: false)
        }
        mergeSummaries(missing + values.map { value in
            .init(reference: .telegram(value.chat), title: value.title,
                  activity: value.date > 0 ? Date(timeIntervalSince1970: Double(value.date)) : nil,
                  unread: value.unread, muted: value.muted, attention: value.attention,
                  available: value.available, hidden: value.hidden)
        })
    }
    /// Sort/filter/aggregate on the owner actor. The UI gets scalar layout IDs
    /// and only the summaries in its viewport (76 across all custom folders).
    func presentation(scope: String?, query: String, ranges: [UUID:Range<Int>], telegramOpen: Bool) -> [UUID:SidebarCustomProjection] {
        var result: [UUID:SidebarCustomProjection] = [:], budget = 76
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for folder in catalog.custom {
            var projection = SidebarCustomProjection()
            let values = (sortedRows[folder.id] ?? []).filter { row in
                if row.hidden { return false }
                if case .agentpad(let ref) = row.reference, let other = ref.scope, let scope, scope != other {
                    projection.foreign += 1; return false
                }
                if case .telegram = row.reference {
                    if !telegramOpen { projection.waitingForTelegram = binding != nil; return false }
                    return true
                }
                return query.isEmpty || row.title.localizedCaseInsensitiveContains(query)
            }
            projection.items = values.map(\.reference)
            projection.unread = values.filter(\.unread).count
            projection.unmuted = values.filter { $0.unread && !$0.muted }.count
            projection.attention = values.contains(where: \.attention)
            if let range = ranges[folder.id] {
                for index in range where values.indices.contains(index) && budget > 0 {
                    var value = values[index]
                    if case .agentpad(let ref) = value.reference, ref.scope != nil, scope == nil {
                        value.title = "Not connected"; value.available = false
                    }
                    projection.rows[value.reference] = value; budget -= 1
                }
            }
            result[folder.id] = projection
        }
        return result
    }
    private func publish() {
        guard publishedRevision != stateRevision else { return }
        defer { publishedRevision = stateRevision }
        var next = SidebarFoldersSnapshot(catalog: catalog,binding: binding)
        next.metadataRevision = snapshot.metadataRevision
        var metadataChanged = false
        let folders = Set(catalog.custom.map(\.id))
        sortedRows = sortedRows.filter { folders.contains($0.key) }
        viewports = viewports.filter { folders.contains($0.key) }
        for folder in catalog.custom {
            let members = Set(folder.items.map(SidebarItemReference.agentpad)).union((telegramMembers[folder.id] ?? []).map(SidebarItemReference.telegram))
            next.members[folder.id] = members
            let old = sortedRows[folder.id] ?? []
            let values = members.map { reference in
                summaries[reference] ?? SidebarItemSummary(reference: reference, title: "Unavailable", activity: nil, available: false)
            }
            let byReference = Dictionary(uniqueKeysWithValues: values.map { ($0.reference,$0) })
            if snapshot.members[folder.id] == members, Set(old.map(\.reference)) == members,
               old.allSatisfy({ old in byReference[old.reference] == old }) {
                sortedRows[folder.id] = old
            } else {
                sortedRows[folder.id] = values.sorted(by: SidebarItemSummary.precedes)
                metadataChanged = true
            }
            if let viewport = viewports[folder.id], let sorted = sortedRows[folder.id] {
                let start = min(viewport.lowerBound,sorted.count), end = min(viewport.upperBound,sorted.count)
                next.rows[folder.id] = Array(sorted[start..<end])
            }
        }
        if metadataChanged { next.metadataRevision &+= 1 }
        next.revision = snapshot.revision
        guard next != snapshot else { return }
        next.revision &+= 1; snapshot = next
        for observer in observers.values { observer.yield(snapshot) }
    }
}

private final class SidebarProviderDeadline<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T,any Error>?
    private var tasks: [Task<Void,Never>] = []
    private var finished = false
    private func complete(_ result: Result<T,any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let continuation = continuation; self.continuation = nil
        let tasks = tasks; self.tasks = []; lock.unlock()
        for task in tasks { task.cancel() }
        continuation?.resume(with: result)
    }
    static func run(timeout: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = SidebarProviderDeadline<T>()
        return try await withCheckedThrowingContinuation { continuation in
            race.continuation = continuation
            let work = Task.detached { do { race.complete(.success(try await operation())) } catch { race.complete(.failure(error)) } }
            let timer = Task.detached {
                do { try await Task.sleep(for: timeout); race.complete(.failure(SidebarFolderFailure.timeout)) } catch {}
            }
            race.lock.lock()
            if race.finished { race.lock.unlock(); work.cancel(); timer.cancel() }
            else { race.tasks = [work,timer]; race.lock.unlock() }
        }
    }
}

enum SidebarFoldersDisk {
    static func write(_ bytes: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".sidebar-folders-\(UUID().uuidString)")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SidebarFolderFailure.storage }
        defer { Darwin.close(fd); unlink(temporary.path) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let size = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if size < 0, errno == EINTR { continue }
                guard size > 0 else { throw SidebarFolderFailure.storage }; offset += size
            }
        }
        guard fsync(fd) == 0, rename(temporary.path,url.path) == 0 else { throw SidebarFolderFailure.storage }
        let directory = Darwin.open(parent.path,O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw SidebarFolderFailure.storage }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else { throw SidebarFolderFailure.storage }
    }
}
