import Foundation
import Observation

/// A local contact, independent of workspaces, team accounts and tool history.
struct AgentProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let templateID: String
    let rosterID: String
    var folder: URL
    /// Frozen at creation. An empty value deliberately bypasses global options.
    var launchOptions: String
    let createdAt: Date
}

struct AgentProfileBinding: Codable, Equatable, Identifiable, Sendable {
    let profileID: UUID
    var record: AgentSessionRecord
    var id: String { record.id }
}

@MainActor @Observable
final class AgentProfileStore {
    static let shared = AgentProfileStore(fileURL: NSClassFromString("XCTestCase") == nil ? SessionCatalogFiles.directory.appendingPathComponent("agent-profiles.json") : nil)

    enum Problem: Error, LocalizedError {
        case unreadable, missingFolder, missingProfile, duplicate(AgentProfile), shell
        var errorDescription: String? {
            switch self {
            case .unreadable: "Agent profiles could not be read. The saved file has not been replaced."
            case .missingFolder: "Folder not found. Choose an existing folder."
            case .missingProfile: "This agent is no longer available."
            case .duplicate(let profile): "\(profile.name) already uses this agent type in that folder."
            case .shell: "Choose an agent type."
            }
        }
    }
    private struct Archive: Codable, Equatable, Sendable {
        var version = 1
        var profiles: [AgentProfile] = []
        var bindings: [String: AgentProfileBinding] = [:]
    }
    /// Serializes discovery saves with explicit add/move/bind commits. An older
    /// background snapshot can never overwrite a newer explicit change.
    private final class Writer: Sendable {
        let queue = DispatchQueue(label: "agentpad.profile-archive", qos: .utility)
        let fileURL: URL
        let write: @Sendable (Data, URL) throws -> Void
        init(fileURL: URL, write: @escaping @Sendable (Data, URL) throws -> Void) {
            self.fileURL = fileURL; self.write = write
        }
        func save(_ archive: Archive) throws { try write(JSONEncoder().encode(archive), fileURL) }
    }
    let details: AgentProfileDetailsStore
    private var archive = Archive()
    @ObservationIgnored private let writer: Writer?
    @ObservationIgnored private let canonicalize: (URL) -> URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveRevision = 0
    @ObservationIgnored private var needsSave = false
    @ObservationIgnored private var seenRecords: [String: AgentSessionRecord] = [:]
    @ObservationIgnored private var canonicalCwds: [String: URL] = [:]
    @ObservationIgnored private let adoptionIO: AgentProfileAdoption.IO
    private struct AdoptionSource {
        let candidates: @MainActor () -> [AgentProfileAdoption.Candidate]
        let apply: @MainActor ([UUID: AgentProfileAdoption.Assignment]) -> Void
    }
    @ObservationIgnored private var adoptionSources: [UUID: AdoptionSource] = [:]
    @ObservationIgnored private var adoptionTask: Task<Void, Never>?
    private var loadFailed = false
    private(set) var problem: String?
    var profiles: [AgentProfile] { archive.profiles }
    var bindings: [AgentProfileBinding] { Array(archive.bindings.values) }

    init(fileURL: URL? = nil, details: AgentProfileDetailsStore? = nil, write: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }, canonicalize: @escaping (URL) -> URL = canonicalDiskPath, adoptionIO: AgentProfileAdoption.IO = .init()) {
        let details = details ?? AgentProfileDetailsStore(fileURL: fileURL?.deletingLastPathComponent().appendingPathComponent("agent-profile-details.json"))
        self.details = details
        self.writer = fileURL.map { Writer(fileURL: $0, write: write) }
        self.canonicalize = canonicalize
        self.adoptionIO = adoptionIO
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let saved = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
                guard saved.version == 1 else { throw Problem.unreadable }
                archive = saved
            } catch { loadFailed = true; problem = Problem.unreadable.localizedDescription }
        }
    }

    func report(_ error: Error) { problem = error.localizedDescription }

    func profile(_ id: UUID) -> AgentProfile? { profiles.first { $0.id == id } }
    func existing(rosterID: String, folder: URL, templateID: String? = nil, launchOptions: String? = nil) -> AgentProfile? {
        let path = canonicalize(folder)
        return profiles.first { $0.rosterID == rosterID && (templateID == nil || $0.templateID == templateID) && (launchOptions == nil || $0.launchOptions == launchOptions) && FileOperations.sameItem(canonicalize($0.folder), path) }
    }
    func binding(agentID: String, conversationID: String) -> AgentProfileBinding? {
        archive.bindings["\(agentID):\(conversationID)"]
    }

    /// Coalesce restore/create/move events across windows before copying tab
    /// state. A source is weakly owned by its window; hidden tabs are included.
    func scheduleTabAdoption(sourceID: UUID, candidates: @escaping @MainActor () -> [AgentProfileAdoption.Candidate],
                             apply: @escaping @MainActor ([UUID: AgentProfileAdoption.Assignment]) -> Void) {
        adoptionSources[sourceID] = AdoptionSource(candidates: candidates, apply: apply)
        guard adoptionTask == nil else { return }
        adoptionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            while !adoptionSources.isEmpty {
                let sources = adoptionSources
                adoptionSources = [:]
                var tabs: [UUID: AgentProfileAdoption.Candidate] = [:]
                for source in sources.values {
                    for candidate in source.candidates() { tabs[candidate.tabID] = candidate }
                }
                guard !tabs.isEmpty else {
                    if needsSave { scheduleSave() }
                    continue
                }
                let snapshot = profiles, io = adoptionIO, candidates = Array(tabs.values)
                do {
                    guard !loadFailed else { throw Problem.unreadable }
                    let result = try await Task.detached(priority: .utility) {
                        try AgentProfileAdoption.resolve(candidates, profiles: snapshot, io: io)
                    }.value
                    // An explicit add/move/edit during I/O wins. Rebuild the
                    // index from current profiles rather than commit stale keys.
                    guard profiles == snapshot else {
                        adoptionSources.merge(sources) { current, _ in current }
                        continue
                    }
                    archive.profiles.append(contentsOf: result.profiles)
                    var changed = !result.profiles.isEmpty
                    for binding in result.bindings where archive.bindings[binding.id] == nil {
                        try bind(binding.record, to: binding.profileID, deferred: true)
                        changed = true
                    }
                    if changed || needsSave { scheduleSave() }
                    for source in sources.values { source.apply(result.assignments) }
                } catch { report(error) }
            }
            adoptionTask = nil
        }
    }

    /// Also useful to wait for restore adoption without loading the catalog.
    func waitForTabAdoption() async { await adoptionTask?.value }

    /// Input is canonicalized once per folder before this lexical check.
    /// Include both macOS spellings and use component boundaries for siblings.
    nonisolated static func isAdoptableFolder(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path.lowercased()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path.lowercased()
        guard folder.isFileURL, path != "/", path != home else { return false }
        guard !folder.pathComponents.contains(where: { [".cache", "cache", "caches"].contains($0.lowercased()) }) else { return false }
        let excluded = [NSTemporaryDirectory(), "/tmp", "/private/tmp", "/var/folders", "/private/var/folders",
            home + "/Library", home + "/.cache", "/Library/Caches", "/System/Library/Caches"]
            + FileManager.default.urls(for: .cachesDirectory, in: .allDomainsMask).map(\.path)
            + [ProcessInfo.processInfo.environment["XDG_CACHE_HOME"]].compactMap { $0 }
        return !excluded.contains {
            // URL.standardizedFileURL can strip /private from an existing
            // root while retaining it on a not-yet-existing descendant.
            let root = ($0.hasSuffix("/") ? String($0.dropLast()) : $0).lowercased()
            return pathIsInside(path, root: root)
        }
    }

    /// Only writes our archive. No process launch, scan or tool configuration.
    @discardableResult
    func add(template: AgentTemplate, folder: URL, name: String = "", launchOptions: String = "") throws -> AgentProfile {
        guard !template.isShell else { throw Problem.shell }
        let folder = canonicalize(folder)
        if let existing = existing(rosterID: template.rosterId, folder: folder, templateID: template.id, launchOptions: launchOptions) { return existing }
        guard isDirectory(folder) else { throw Problem.missingFolder }
        let profile = AgentProfile(id: UUID(), name: normalizedTitle(name) ?? (folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent),
            templateID: template.id, rosterID: template.rosterId, folder: folder, launchOptions: launchOptions, createdAt: Date())
        var next = archive; next.profiles.append(profile)
        try commit(next)
        discoverSeenRecords()
        return profile
    }

    func move(_ id: UUID, to folder: URL) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw Problem.missingProfile }
        let folder = canonicalize(folder)
        guard isDirectory(folder) else { throw Problem.missingFolder }
        if let other = existing(rosterID: profiles[index].rosterID, folder: folder, templateID: profiles[index].templateID, launchOptions: profiles[index].launchOptions), other.id != id {
            throw Problem.duplicate(other)
        }
        var next = archive; next.profiles[index].folder = folder
        try commit(next)
        discoverSeenRecords()
    }

    /// Existing ownership and cwd never change, including when discovery reports
    /// a moved transcript, a retargeted symlink, or a newly reused old folder.
    func discover(_ records: [AgentSessionRecord]) throws {
        guard !loadFailed else { throw Problem.unreadable }
        var next = archive
        var changed = false
        for record in records where seenRecords[record.id] != record {
            seenRecords[record.id] = record
            if discover(record, into: &next) { changed = true }
        }
        if changed { archive = next; scheduleSave() }
        else if needsSave, saveTask == nil { scheduleSave() }
    }

    private func discoverSeenRecords() {
        var next = archive
        var changed = false
        for record in seenRecords.values where next.bindings[record.id] == nil {
            if discover(record, into: &next) { changed = true }
        }
        if changed { archive = next; scheduleSave() }
    }

    private func discover(_ record: AgentSessionRecord, into next: inout Archive) -> Bool {
        let binding: AgentProfileBinding
        if var bound = next.bindings[record.id] {
            let old = bound.record
            bound.record = AgentSessionRecord(agentId: old.agentId, conversationId: old.conversationId,
                title: record.title, cwd: old.cwd, lastActivity: max(old.lastActivity, record.lastActivity),
                agentTitle: record.agentTitle, summary: record.summary, firstPrompt: record.firstPrompt,
                automatic: record.automatic, startedAt: record.startedAt, fileURL: record.fileURL)
            binding = bound
        } else {
            // With no matching tool there is no reason to resolve any disk paths.
            guard let origin = details.archive.origins[record.id] else { return false }
            let cwd = canonicalCwds[record.id] ?? canonicalize(record.cwd)
            canonicalCwds[record.id] = cwd
            guard let profile = next.profiles.first(where: { $0.rosterID == record.agentId && $0.templateID == origin.templateID && $0.launchOptions == origin.options && FileOperations.sameItem($0.folder, cwd) }) else { return false }
            binding = AgentProfileBinding(profileID: profile.id, record: canonicalRecord(record, cwd: cwd))
        }
        guard next.bindings[record.id] != binding else { return false }
        next.bindings[record.id] = binding
        return true
    }

    /// Explicit launches attach before discovery, which may arrive after a move.
    /// Deferred adoption supplies a canonical record and batches the archive
    /// save after all bindings. It must not resolve paths on MainActor again.
    func bind(_ record: AgentSessionRecord, to profileID: UUID, origin: AgentLaunchOrigin? = nil, deferred: Bool = false) throws {
        guard let profile = profile(profileID), profile.rosterID == record.agentId else { throw Problem.missingProfile }
        if let origin { try details.remember(origin, conversation: record.conversationId) }
        guard archive.bindings[record.id] == nil else { return }
        if deferred {
            archive.bindings[record.id] = AgentProfileBinding(profileID: profileID, record: record)
        } else {
            var next = archive
            next.bindings[record.id] = AgentProfileBinding(profileID: profileID, record: canonicalRecord(record))
            try commit(next)
        }
    }

    func rename(_ id: UUID, to name: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw Problem.missingProfile }
        guard let name = normalizedTitle(name), InlineNameEdit.problem(name) == nil else { throw CocoaError(.validationMissingMandatoryProperty) }
        var next = archive; next.profiles[index].name = name
        try commit(next)
    }

    /// Backup precedes the first automatic mapping. Replays are idempotent.
    func prepareMapping() throws {
        guard !loadFailed else { throw Problem.unreadable }
        try details.checkReadable()
        if let writer {
            try writer.queue.sync {
                let backup = writer.fileURL.appendingPathExtension("backup")
                if FileManager.default.fileExists(atPath: writer.fileURL.path), !FileManager.default.fileExists(atPath: backup.path) {
                    try AgentProfileDetailsStore.writePrivate(Data(contentsOf: writer.fileURL), backup)
                }
            }
        }
    }

    func mapPublications(_ agents: [TeamPublishedAgent]) throws {
        for agent in agents where details.archive.publications[agent.id.uuidString] == nil {
            let folder = URL(fileURLWithPath: (agent.folder as NSString).expandingTildeInPath)
            guard isDirectory(folder) else { continue }
            try prepareMapping()
            let profile = try add(template: .claudeCode, folder: folder)
            var next = details.archive; next.publications[agent.id.uuidString] = profile.id
            try details.commit(next)
        }
    }

    func records(for profileID: UUID) -> [AgentSessionRecord] {
        bindings.filter { $0.profileID == profileID }.map(\.record).sorted {
            $0.lastActivity != $1.lastActivity ? $0.lastActivity > $1.lastActivity : $0.id < $1.id
        }
    }

    private func canonicalRecord(_ record: AgentSessionRecord, cwd: URL? = nil) -> AgentSessionRecord {
        AgentSessionRecord(agentId: record.agentId, conversationId: record.conversationId, title: record.title,
            cwd: cwd ?? canonicalize(record.cwd), lastActivity: record.lastActivity, agentTitle: record.agentTitle,
            summary: record.summary, firstPrompt: record.firstPrompt, automatic: record.automatic,
            startedAt: record.startedAt, fileURL: record.fileURL)
    }
    private func commit(_ next: Archive) throws {
        do {
            guard !loadFailed else { throw Problem.unreadable }
            if let writer { try writer.queue.sync { try writer.save(next) } }
            saveTask?.cancel(); saveTask = nil; saveRevision += 1; needsSave = false
            archive = next; problem = nil
        } catch { problem = error.localizedDescription; throw error }
    }

    /// Explicit shutdown/save drains committed discovery and adoption changes;
    /// their normal encoding/writes use the debounced background path below.
    func flush() throws {
        if needsSave { try commit(archive) }
    }

    private func scheduleSave() {
        guard writer != nil else { return }
        needsSave = true; saveRevision += 1
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, let writer else { return }
            let revision = saveRevision, snapshot = archive
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    writer.queue.async { continuation.resume(with: Result { try writer.save(snapshot) }) }
                }
                guard revision == saveRevision else { return }
                needsSave = false; problem = nil
            } catch {
                guard revision == saveRevision else { return }
                problem = error.localizedDescription
            }
            saveTask = nil
        }
    }
}
