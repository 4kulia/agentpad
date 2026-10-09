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
    static let shared = AgentProfileStore(fileURL: SessionCatalogFiles.directory.appendingPathComponent("agent-profiles.json"))

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
    private var archive = Archive()
    @ObservationIgnored private let writer: Writer?
    @ObservationIgnored private let canonicalize: (URL) -> URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveRevision = 0
    @ObservationIgnored private var needsSave = false
    @ObservationIgnored private var seenRecords: [String: AgentSessionRecord] = [:]
    @ObservationIgnored private var canonicalCwds: [String: URL] = [:]
    private var loadFailed = false
    private(set) var problem: String?
    var profiles: [AgentProfile] { archive.profiles }
    var bindings: [AgentProfileBinding] { Array(archive.bindings.values) }

    init(fileURL: URL? = nil, write: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }, canonicalize: @escaping (URL) -> URL = canonicalDiskPath) {
        self.writer = fileURL.map { Writer(fileURL: $0, write: write) }
        self.canonicalize = canonicalize
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let saved = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
                guard saved.version == 1 else { throw Problem.unreadable }
                archive = saved
            } catch { loadFailed = true; problem = Problem.unreadable.localizedDescription }
        }
    }

    func profile(_ id: UUID) -> AgentProfile? { profiles.first { $0.id == id } }
    func existing(rosterID: String, folder: URL) -> AgentProfile? {
        let path = canonicalize(folder)
        return profiles.first { $0.rosterID == rosterID && FileOperations.sameItem(canonicalize($0.folder), path) }
    }
    func binding(agentID: String, conversationID: String) -> AgentProfileBinding? {
        archive.bindings["\(agentID):\(conversationID)"]
    }

    /// Only writes our archive. No process launch, scan or tool configuration.
    @discardableResult
    func add(template: AgentTemplate, folder: URL, name: String = "", launchOptions: String = "") throws -> AgentProfile {
        guard !template.isShell else { throw Problem.shell }
        let folder = canonicalize(folder)
        if let existing = existing(rosterID: template.rosterId, folder: folder) { return existing }
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
        if let other = existing(rosterID: profiles[index].rosterID, folder: folder), other.id != id {
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
            guard next.profiles.contains(where: { $0.rosterID == record.agentId }) else { return false }
            let cwd = canonicalCwds[record.id] ?? canonicalize(record.cwd)
            canonicalCwds[record.id] = cwd
            guard let profile = next.profiles.first(where: { $0.rosterID == record.agentId && $0.folder.path == cwd.path }) else { return false }
            binding = AgentProfileBinding(profileID: profile.id, record: canonicalRecord(record, cwd: cwd))
        }
        guard next.bindings[record.id] != binding else { return false }
        next.bindings[record.id] = binding
        return true
    }

    /// Explicit launches attach before discovery, which may arrive after a move.
    func bind(_ record: AgentSessionRecord, to profileID: UUID) throws {
        guard let profile = profile(profileID), profile.rosterID == record.agentId else { throw Problem.missingProfile }
        guard archive.bindings[record.id] == nil else { return }
        var next = archive
        next.bindings[record.id] = AgentProfileBinding(profileID: profileID, record: canonicalRecord(record))
        try commit(next)
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

    /// Explicit shutdown/save drains discovery too; encoding/writes during scans
    /// use the debounced background path below.
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
