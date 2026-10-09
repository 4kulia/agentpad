import Foundation

/// Each form opts fields into persistence. No dictionary of UI values, env,
/// credentials, caller objects, signed URLs or pending decisions is encodable.
struct TabDraft: Codable, Equatable, Identifiable {
    enum Payload: Codable, Equatable {
        case ask(prompt: String, contextIDs: [String])
        case forward(snapshot: String, markdown: String, destination: OrgKey?, channelID: String?, threadID: String?, attemptID: UUID?)
        case publication(name: String, folder: String, instructions: String, teamIDs: [String])
        case publicationForm(PublicationDraft)
        case organizationForm(OrganizationDraft)
        case newAgent(NewAgentDraft)
        case ssh(name: String, host: String, directory: String)
        case worktree(branch: String, directory: String)
        case worktreeForm(WorktreeFormDraft)
        case workspaceTag(WorkspaceTagDraft)
        case fileName(FileNameDraft)
        case channel(name: String)
        case newChannelForm(NewChannelDraft)
        case forwardForm(ForwardDraft)
        case reason(String)
    }
    let id: UUID
    var revision: Int
    let route: ToolRoute
    var payload: Payload
}

@MainActor @Observable
final class DraftRepository {
    enum Problem: Error, LocalizedError {
        case stale, unsupported
        var errorDescription: String? {
            switch self {
            case .stale: "A newer draft is already saved. Your version has been kept for review."
            case .unsupported: "The draft file cannot be read. It has not been replaced."
            }
        }
    }
    private struct Archive: Codable {
        var version = 1
        var drafts: [UUID: TabDraft] = [:]
        var conflicts: [TabDraft] = []
    }
    private var archive = Archive()
    private let fileURL: URL?
    private let write: (Data, URL) throws -> Void
    private(set) var loadError: Error?

    init(fileURL: URL? = nil, write: @escaping (Data, URL) throws -> Void = { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }) {
        self.fileURL = fileURL; self.write = write
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
                guard archive.version == 1 else { throw Problem.unsupported }
            } catch { loadError = Problem.unsupported }
        }
    }
    var drafts: [TabDraft] { Array(archive.drafts.values) }
    var conflicts: [TabDraft] { archive.conflicts }
    func draft(_ id: UUID) -> TabDraft? { archive.drafts[id] }
    func save(_ draft: TabDraft) throws {
        guard loadError == nil else { throw Problem.unsupported }
        var next = archive
        if let saved = next.drafts[draft.id], saved != draft, saved.revision >= draft.revision {
            if !next.conflicts.contains(draft) { next.conflicts.append(draft); try commit(next) }
            throw Problem.stale
        }
        next.drafts[draft.id] = draft
        try commit(next)
    }
    func discard(_ id: UUID) throws {
        var next = archive; next.drafts[id] = nil
        next.conflicts.removeAll { $0.id == id }
        try commit(next)
    }
    private func commit(_ next: Archive) throws {
        if let loadError { throw loadError }
        if let fileURL { try write(JSONEncoder().encode(next), fileURL) }
        archive = next
    }
}
