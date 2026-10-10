import AppKit
import CryptoKit
import Darwin
import Foundation
import Observation

/// Evidence captured at launch, never reconstructed from a terminal's latest cd.
struct AgentLaunchOrigin: Codable, Equatable, Sendable {
    let templateID: String
    let rosterID: String
    let folder: URL
    let options: String
    let configuration: String

    init(template: AgentTemplate, folder: URL, options: String) {
        templateID = template.id; rosterID = template.rosterId
        self.folder = canonicalDiskPath(folder); self.options = options
        configuration = Self.fingerprint(template)
    }

    func matches(_ template: AgentTemplate) -> Bool {
        template.id == templateID && template.rosterId == rosterID && Self.fingerprint(template) == configuration
    }

    private static func fingerprint(_ template: AgentTemplate) -> String {
        // Store a digest, not another copy of credentials from custom templates.
        let fields = [template.id, template.rosterId, template.initialCommand ?? "",
                      String(describing: template.resumeStrategy), template.promptLaunchFlag ?? ""]
            + template.extraEnv.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] }
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Additive metadata lives beside the v1 archive so older clients cannot erase it.
/// Each link is a completed migration step. Base profiles are committed first;
/// retry finds the same template/options/folder and completes any missing link.
@MainActor @Observable
final class AgentProfileDetailsStore {
    struct Avatar: Codable, Equatable, Sendable {
        var revision = 0
        var file: String?
    }
    struct PublicationLink: Codable, Equatable, Sendable {
        var scope: OrgKey
        var agentID: String
        var profileID: UUID
        var acceptedSessionID: String
    }
    struct Archive: Codable, Equatable, Sendable {
        var version = 1
        var origins: [String: AgentLaunchOrigin] = [:]
        var publications: [String: UUID] = [:]
        var avatars: [UUID: Avatar] = [:]
        var confirmedPublications: [PublicationLink]?
        var publishedAvatars: [PublishedAvatar]?
    }
    @ObservationIgnored var avatarImages: [UUID: (Int, NSImage?)] = [:]
    private(set) var archive = Archive()
    private var persistenceProblem: String?
    private(set) var avatarCleanupProblem: String?
    var problem: String? { persistenceProblem ?? avatarCleanupProblem }
    let fileURL: URL?
    private var unreadable = false
    @ObservationIgnored private let write: (Data, URL) throws -> Void

    init(fileURL: URL? = nil, write: @escaping (Data, URL) throws -> Void = AgentProfileDetailsStore.writePrivate) {
        self.fileURL = fileURL; self.write = write
        defer { cleanupAvatars() }
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
            guard archive.version == 1 else { throw AgentProfileStore.Problem.unreadable }
        } catch { unreadable = true; persistenceProblem = "Agent profile details could not be read. The saved file has not been replaced." }
    }

    func checkReadable() throws { if unreadable { throw AgentProfileStore.Problem.unreadable } }

    func commit(_ next: Archive) throws {
        guard !unreadable else { throw AgentProfileStore.Problem.unreadable }
        guard next != archive else { return }
        do {
            if let fileURL {
                // One immutable pre-migration copy, including unknown legacy data.
                let backup = fileURL.appendingPathExtension("backup")
                if FileManager.default.fileExists(atPath: fileURL.path), !FileManager.default.fileExists(atPath: backup.path) {
                    try write(Data(contentsOf: fileURL), backup)
                }
                try write(JSONEncoder().encode(next), fileURL)
            }
            archive = next; persistenceProblem = nil
        } catch { persistenceProblem = error.localizedDescription; throw error }
    }

    /// The committed references are the cleanup journal. Interrupted writes and
    /// failed deletions remain discoverable on the next save/remove or launch.
    func cleanupAvatars() {
        guard !unreadable, let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent().appendingPathComponent("profile-assets")
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { avatarCleanupProblem = nil; return }
        let referenced = Set(archive.avatars.keys.compactMap { avatarURL($0)?.standardizedFileURL.path })
        var failure: Error?
        guard let files = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            errorHandler: { _, error in failure = failure ?? error; return true }) else {
            avatarCleanupProblem = "Unused avatar files could not be read. Cleanup will retry after the next save or restart."
            return
        }
        for case let file as URL in files {
            do {
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true && values.isSymbolicLink != true { continue }
                if !referenced.contains(file.standardizedFileURL.path) { try fm.removeItem(at: file) }
            } catch { failure = failure ?? error }
        }
        avatarCleanupProblem = failure.map {
            "Unused avatar files could not be removed. Cleanup will retry after the next save or restart: \($0.localizedDescription)"
        }
    }

    func remember(_ origin: AgentLaunchOrigin, conversation: String) throws {
        let key = "\(origin.rosterID):\(conversation)"
        guard archive.origins[key] == nil else { return }
        var next = archive; next.origins[key] = origin
        try commit(next)
    }

    nonisolated static func writePrivate(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".profile-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
