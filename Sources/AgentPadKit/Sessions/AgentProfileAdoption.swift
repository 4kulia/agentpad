import Darwin
import Foundation

/// Tab launch state, independent of hooks, rollout guesses and catalog loading.
enum AgentProfileAdoption {
    struct Candidate: Equatable, Sendable {
        let tabID: UUID
        let rosterID: String
        let templateID: String
        let launchOptions: String
        let folder: URL
        /// Captured before restore can refuse/drop a saved resume ID. Reports
        /// received later are not evidence for adoption.
        let conversationID: String?
        let title: String
        let createdAt: Date
    }

    struct FileIdentity: Hashable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    struct Folder: Sendable {
        let url: URL
        let identity: FileIdentity?
        let isDirectory: Bool

        static func read(_ url: URL) -> Self {
            let canonical = canonicalDiskPath(url)
            var info = stat()
            let exists = stat(canonical.path, &info) == 0
            return Self(url: canonical,
                identity: exists ? FileIdentity(device: info.st_dev, inode: info.st_ino) : nil,
                isDirectory: exists && info.st_mode & S_IFMT == S_IFDIR)
        }
    }

    struct IO: Sendable {
        var executorIDs: @Sendable () throws -> Set<String> = { try ExecutorConversations(files: .standard).ids() }
        var folder: @Sendable (URL) -> Folder = Folder.read
    }

    struct Assignment: Sendable {
        let candidate: Candidate
        let profileID: UUID
        let folder: URL
    }

    struct Result: Sendable {
        var profiles: [AgentProfile] = []
        var bindings: [AgentProfileBinding] = []
        var assignments: [UUID: Assignment] = [:]
    }

    private struct Configuration: Hashable {
        let rosterID: String
        let templateID: String
        let options: String
    }
    private enum Location: Hashable {
        case path(String)
        case file(FileIdentity)
    }
    private struct Key: Hashable {
        let configuration: Configuration
        let location: Location
    }

    /// Runs entirely off MainActor. Index both canonical path and device/inode
    /// (the same-item equivalence) once per folder; never compare pairs of tabs.
    static func resolve(_ candidates: [Candidate], profiles: [AgentProfile], io: IO) throws -> Result {
        let executorIDs = Set(try io.executorIDs().map { $0.lowercased() })
        var folders: [URL: Folder] = [:]
        func folder(_ url: URL) -> Folder {
            if let cached = folders[url] { return cached }
            let value = io.folder(url)
            folders[url] = value
            return value
        }
        var index: [Key: UUID] = [:]
        func keys(_ configuration: Configuration, _ folder: Folder) -> [Key] {
            [Key(configuration: configuration, location: .path(folder.url.path))]
                + (folder.identity.map { [Key(configuration: configuration, location: .file($0))] } ?? [])
        }
        for profile in profiles {
            let config = Configuration(rosterID: profile.rosterID, templateID: profile.templateID, options: profile.launchOptions)
            for key in keys(config, folder(profile.folder)) where index[key] == nil { index[key] = profile.id }
        }
        var result = Result()
        for candidate in candidates {
            if let id = candidate.conversationID, executorIDs.contains(id.lowercased()) { continue }
            let folder = folder(candidate.folder)
            guard folder.isDirectory, AgentProfileStore.isAdoptableFolder(folder.url) else { continue }
            let config = Configuration(rosterID: candidate.rosterID, templateID: candidate.templateID, options: candidate.launchOptions)
            let keys = keys(config, folder)
            let id: UUID
            if let existing = keys.compactMap({ index[$0] }).first {
                id = existing
            } else {
                id = UUID()
                result.profiles.append(AgentProfile(id: id, name: folder.url.lastPathComponent,
                    templateID: candidate.templateID, rosterID: candidate.rosterID, folder: folder.url,
                    launchOptions: candidate.launchOptions, createdAt: candidate.createdAt))
            }
            for key in keys { index[key] = id }
            result.assignments[candidate.tabID] = Assignment(candidate: candidate, profileID: id, folder: folder.url)
            if let conversation = candidate.conversationID {
                result.bindings.append(AgentProfileBinding(profileID: id, record: AgentSessionRecord(
                    agentId: candidate.rosterID, conversationId: conversation, title: candidate.title,
                    cwd: folder.url, lastActivity: candidate.createdAt)))
            }
        }
        return result
    }
}
