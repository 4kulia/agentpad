import Foundation

/// Global "recent project folders" list — the zero-config answer to "let me
/// add my project directories like Codex" (issue #28): AgentPad just remembers
/// every folder a workspace was opened on. Backs File → Open Recent and the
/// ⌘P recent-folder entries.
///
/// Own JSON file rather than a `state.json` field: the list is app-global
/// while `state.json` is written per window on independent debounce timers —
/// separate files mean the two can never race or clobber each other.
@MainActor
final class RecentFolders {
    static let shared = RecentFolders()

    static let cap = 20

    /// Most recent first; standardized paths, deduped at insert.
    private(set) var paths: [String] = []

    private let fileURL: URL

    static var defaultFileURL: URL {
        AgentPadShellIntegration.agentPadAppSupport("recent-folders.json", isDirectory: false)
    }

    /// `fileURL` injectable so tests write a scratch file instead of the
    /// user's real App Support list (same seam shape as `AppPersistence`).
    init(fileURL: URL = RecentFolders.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    /// Folders that still exist on disk, most recent first. Dead entries
    /// (deleted projects, unmounted volumes) are display-filtered rather
    /// than purged — a briefly unmounted volume's projects come back with it.
    var existing: [URL] {
        paths.compactMap { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return isDirectory(url) ? url : nil
        }
    }

    /// LRU insert: newest first, a re-noted entry moves to the front. The
    /// home directory is excluded here — it's every fresh workspace's default
    /// cwd, not a project anyone needs "recent" access to.
    func note(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard path != NSHomeDirectory(), paths.first != path else { return }
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > Self.cap { paths.removeLast(paths.count - Self.cap) }
        save()
    }

    func clear() {
        guard !paths.isEmpty else { return }
        paths = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        paths = Array(decoded.prefix(Self.cap))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(paths) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
