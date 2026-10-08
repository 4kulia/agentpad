import AppKit
import Foundation

/// File operations for the sidebar tree. Plain FileManager calls on the
/// general pasteboard, so copy/paste interoperates with Finder both ways.
/// Deletion only ever goes to the Trash.
///
/// The tree's kqueue watchers pick up every change made here, so callers
/// don't refresh anything themselves.
enum FileOperations {
    // MARK: Names

    /// `name 2.ext`, `name 3.ext`… — Finder's "Keep Both" naming.
    static func uniqueURL(for proposed: URL, exists: (URL) -> Bool = defaultExists) -> URL {
        guard exists(proposed) else { return proposed }
        let directory = proposed.deletingLastPathComponent()
        let (base, ext) = split(proposed.lastPathComponent)
        var n = 2
        while true {
            let candidate = directory.appendingPathComponent(join(base: "\(base) \(n)", ext: ext))
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// `name copy.ext`, `name copy 2.ext`… — Finder's Duplicate naming.
    static func duplicateURL(for source: URL, exists: (URL) -> Bool = defaultExists) -> URL {
        let (base, ext) = split(source.lastPathComponent)
        let first = source.deletingLastPathComponent().appendingPathComponent(join(base: "\(base) copy", ext: ext))
        return uniqueURL(for: first, exists: exists)
    }

    /// Splits `archive.tar.gz` as `archive.tar` + `gz`, and keeps dotfiles
    /// (`.env`) whole.
    static func split(_ name: String) -> (base: String, ext: String?) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, nil) }
        let ext = String(name[name.index(after: dot)...])
        return ext.isEmpty ? (name, nil) : (String(name[..<dot]), ext)
    }

    private static func join(base: String, ext: String?) -> String {
        ext.map { "\(base).\($0)" } ?? base
    }

    static let defaultExists: @Sendable (URL) -> Bool = { url in
        // lstat, so a dangling symlink still counts as taken.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Why a new name is unusable, or nil when it's fine.
    static func renameProblem(_ name: String, in directory: URL, current: String? = nil, exists: (URL) -> Bool = defaultExists) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "The name can't be empty." }
        if trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { return "The name can't contain control characters." }
        if trimmed.contains("/") || trimmed.contains(":") { return "The name can't contain “/” or “:”." }
        if trimmed == "." || trimmed == ".." { return "That name is reserved." }
        if trimmed == current { return nil }
        // A case-only rename on a case-insensitive volume finds "itself".
        if let current, trimmed.lowercased() == current.lowercased(),
           (try? FileManager.default.contentsOfDirectory(atPath: directory.path).contains(trimmed)) == false,
           sameItem(directory.appendingPathComponent(current), directory.appendingPathComponent(trimmed)) { return nil }
        if exists(directory.appendingPathComponent(trimmed)) { return "“\(trimmed)” already exists here." }
        return nil
    }

    // MARK: Pasteboard

    /// What a paste would do with the pasteboard's files.
    enum PasteMode: String, Codable, Sendable { case copy, move }

    /// Files cut in this app. A cut is just a copy plus this note; it turns the
    /// next paste into a move as long as nobody has written to the pasteboard
    /// since (Finder has no cut for files, so this can't leak there).
    @MainActor private static var pendingCut: (urls: [URL], changeCount: Int)?

    @MainActor
    static func copy(_ urls: [URL], cut: Bool = false, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        pendingCut = cut ? (urls, pasteboard.changeCount) : nil
    }

    @MainActor
    static func pasteboardFiles(_ pasteboard: NSPasteboard = .general) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        return objects ?? []
    }

    @MainActor
    static func pasteMode(_ pasteboard: NSPasteboard = .general) -> PasteMode {
        guard let cut = pendingCut, cut.changeCount == pasteboard.changeCount else { return .copy }
        return .move
    }

    @MainActor
    static func canPaste(_ pasteboard: NSPasteboard = .general) -> Bool {
        !pasteboardFiles(pasteboard).isEmpty
    }

    // MARK: Transfers

    enum ConflictChoice: Equatable, Sendable { case replace, keepBoth, skip, stop }

    struct Failure: Codable, Equatable, Sendable {
        let url: URL
        let message: String
    }

    struct TransferResult: Codable, Equatable, Sendable {
        var done: [URL] = []
        /// Sources that were copied/moved (for keeping a partial cut alive).
        var doneSources: [URL] = []
        var skipped: [URL] = []
        var issues: [Failure] = []
        var failures: [String] { issues.map(\.message) }
    }

    /// The real location: symlinks resolved, `/private` prefix normalized.
    static func realPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Whether two URLs are the same file on disk (symlinks, case
    /// differences on case-insensitive volumes and hard links included).
    static func sameItem(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let ida = try? a.resourceValues(forKeys: key).fileResourceIdentifier,
              let idb = try? b.resourceValues(forKeys: key).fileResourceIdentifier
        else { return realPath(a) == realPath(b) }
        return ida.isEqual(idb)
    }

    static func isInside(_ path: String, _ ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }

    /// Copies or moves `sources` into `directory`. `resolve` is asked once per
    /// name clash; pasting into the source's own folder never asks and makes
    /// a "copy" instead, like Finder. Replace is staged: the new item is
    /// written under a temporary name first, the old one goes to the Trash
    /// only once that succeeded, so a failure never loses the original.
    @discardableResult
    static func transfer(
        _ sources: [URL],
        into directory: URL,
        mode: PasteMode,
        fileManager io: TransferFileIO = TransferFileIO(),
        progress: @Sendable (TransferResult) async -> Void = { _ in },
        resolve: @Sendable (URL) async -> ConflictChoice
    ) async -> TransferResult {
        let fileManager = io.manager
        var result = TransferResult()
        let exists: (URL) -> Bool = { (try? fileManager.attributesOfItem(atPath: $0.path)) != nil }
        let dir = directory.standardizedFileURL
        let realDir = realPath(dir)
        let realSources = sources.map(realPath)
        for source in sources.map(\.standardizedFileURL) {
            if Task.isCancelled { break }
            await progress(result)
            let realSource = realPath(source)
            // A folder into itself or its own subfolder would recurse forever.
            if isInside(realDir, realSource) {
                result.issues.append(Failure(url: source, message: "Can't put “\(source.lastPathComponent)” inside itself."))
                continue
            }
            let directoryIdentity = FileIdentity(dir)?.entry
            var destination = dir.appendingPathComponent(source.lastPathComponent)
            var replacing: URL?
            var replacementIdentity: FileIdentity?
            if exists(destination) {
                if sameItem(destination, source) {
                    // Pasting onto itself: Finder makes a copy; a move is a no-op.
                    if mode == .move { result.skipped.append(source); continue }
                    destination = duplicateURL(for: source, exists: exists)
                } else {
                    let sourceIdentity = FileIdentity(source)
                    let destinationIdentity = FileIdentity(destination)
                    let choice = await resolve(destination)
                    if choice == .stop { return result }
                    if choice == .skip { result.skipped.append(source); continue }
                    guard FileIdentity(source) == sourceIdentity, FileIdentity(destination) == destinationIdentity,
                          FileIdentity(dir)?.entry == directoryIdentity else {
                        result.issues.append(Failure(url: source, message: "Files changed while awaiting a decision. Nothing was replaced."))
                        continue
                    }
                    switch choice {
                    case .stop:
                        return result
                    case .skip:
                        result.skipped.append(source)
                        continue
                    case .keepBoth:
                        destination = uniqueURL(for: destination, exists: exists)
                    case .replace:
                        // Never trash something that contains an item still to be moved.
                        let realDestination = realPath(destination)
                        if realSources.contains(where: { isInside($0, realDestination) }) {
                            result.issues.append(Failure(url: source, message: "Can't replace “\(destination.lastPathComponent)”: it contains an item being moved."))
                            continue
                        }
                        replacing = destination
                        replacementIdentity = destinationIdentity
                    }
                }
            }
            let target = replacing.map { _ in
                dir.appendingPathComponent(".agentpad-\(UUID().uuidString)-\(source.lastPathComponent)")
            } ?? destination
            do {
                switch mode {
                case .copy: try fileManager.copyItem(at: source, to: target)
                case .move: try fileManager.moveItem(at: source, to: target)
                }
            } catch {
                result.issues.append(Failure(url: source, message: "“\(source.lastPathComponent)”: \(error.localizedDescription)"))
                continue
            }
            if let replacing {
                /// Undo the staged copy/move; reports if even that fails.
                func unstage() {
                    do {
                        if mode == .move { try fileManager.moveItem(at: target, to: source) }
                        else { try fileManager.removeItem(at: target) }
                    } catch {
                        result.issues.append(Failure(url: source, message: "The new “\(source.lastPathComponent)” was left as “\(target.lastPathComponent)”: \(error.localizedDescription)"))
                    }
                }
                guard FileIdentity(replacing) == replacementIdentity, FileIdentity(dir)?.entry == directoryIdentity, realPath(dir) == realDir,
                      !realSources.contains(where: { isInside($0, realPath(replacing)) }) else {
                    unstage()
                    result.issues.append(Failure(url: source, message: "The destination changed during staging. Nothing was replaced."))
                    continue
                }
                var trashed: NSURL?
                do {
                    try fileManager.trashItem(at: replacing, resultingItemURL: &trashed)
                } catch {
                    unstage()
                    result.issues.append(Failure(url: source, message: "Couldn't replace “\(replacing.lastPathComponent)”: \(error.localizedDescription)"))
                    continue
                }
                do {
                    try fileManager.moveItem(at: target, to: replacing)
                } catch {
                    // Bring the original back out of the Trash, then undo the staging.
                    var restored = false
                    if let trashed = trashed as URL? {
                        restored = (try? fileManager.moveItem(at: trashed, to: replacing)) != nil
                    }
                    unstage()
                    result.issues.append(Failure(url: source, message: restored
                        ? "Couldn't replace “\(replacing.lastPathComponent)”; it was left unchanged: \(error.localizedDescription)"
                        : "Couldn't replace “\(replacing.lastPathComponent)”; the original is in the Trash: \(error.localizedDescription)"))
                    continue
                }
            }
            result.done.append(destination)
            result.doneSources.append(source)
        }
        await progress(result)
        return result
    }
    /// Pastes the general pasteboard into `directory`, asking about clashes.
    /// File work runs off the main thread; decisions live in the operation tab.
    @MainActor
    static func paste(into directory: URL, editor: FileNameEdit? = nil) {
        let sources = pasteboardFiles()
        guard !sources.isEmpty else { return }
        let mode = pasteMode()
        guard let batch = ProcessTabs.shared.transfer(sources, into: directory, mode: mode) else { return }
        var expectedChangeCount = NSPasteboard.general.changeCount
        batch.onResult = { result in
            // Only our own partial-cut updates may advance this snapshot.
            if mode == .move, NSPasteboard.general.changeCount == expectedChangeCount {
                let moved = Set(result.doneSources.map(\.path))
                let remaining = sources.filter { !moved.contains($0.standardizedFileURL.path) }
                if remaining.isEmpty { pendingCut = nil } else { copy(remaining, cut: true) }
                expectedChangeCount = NSPasteboard.general.changeCount
            }
            report(result.issues, editor: editor)
        }
        Task { _ = await batch.start() }
    }

    /// The operation owns its continuation; no thread waits for the UI.
    @MainActor
    static func transferInBackground(_ sources: [URL], into directory: URL, mode: PasteMode) async -> TransferResult {
        guard let batch = ProcessTabs.shared.transfer(sources, into: directory, mode: mode) else {
            return TransferResult(issues: sources.map { Failure(url: $0, message: "File operations could not be opened.") })
        }
        return await batch.start()
    }

    // MARK: Single-item operations

    @MainActor
    static func trash(_ urls: [URL], editor: FileNameEdit? = nil) {
        Task { @MainActor in
            let failures = await Task.detached(priority: .userInitiated) { () -> [Failure] in
                var failures: [Failure] = []
                for url in urls {
                    do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                    catch { failures.append(Failure(url: url, message: error.localizedDescription)) }
                }
                return failures
            }.value
            report(failures, editor: editor)
        }
    }

    @MainActor
    static func duplicate(_ url: URL, editor: FileNameEdit? = nil) {
        Task { @MainActor in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try FileManager.default.copyItem(at: url, to: duplicateURL(for: url)); return nil }
                catch { return "“\(url.lastPathComponent)”: \(error.localizedDescription)" }
            }.value
            report(failure.map { [Failure(url: url, message: $0)] } ?? [], editor: editor)
        }
    }

    /// Creates `untitled folder` (or `untitled folder 2`…) and returns it.
    @MainActor
    @discardableResult
    static func newFolder(in directory: URL, editor: FileNameEdit? = nil) -> URL? {
        let url = uniqueURL(for: directory.appendingPathComponent("untitled folder"))
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        } catch {
            report([Failure(url: directory, message: error.localizedDescription)], editor: editor)
            return nil
        }
    }

    @MainActor
    static func newFile(in directory: URL, editor: FileNameEdit? = nil, tabs: LocalFormTabs = .shared) {
        (editor?.isVisible == true ? editor : tabs.files(directory))?.beginNew(in: directory)
    }

    /// Creates an empty file, failing (never truncating) if anything already
    /// has that name — even if it appeared after the name was checked.
    static func createExclusively(_ url: URL) -> String? {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else {
            return errno == EEXIST ? "“\(url.lastPathComponent)” already exists here." : "Couldn't create “\(url.lastPathComponent)”: \(String(cString: strerror(errno)))"
        }
        Darwin.close(fd)
        return nil
    }

    @MainActor
    static func rename(_ url: URL, editor: FileNameEdit? = nil, tabs: LocalFormTabs = .shared) {
        (editor?.isVisible == true ? editor : tabs.files(url.deletingLastPathComponent()))?.beginRename(url)
    }

    /// No replacement, including when a competing writer wins after validation.
    /// Rename the directory entry itself, never the target of a symlink.
    static func renameItem(_ url: URL, to name: String) -> String? {
        let directory = url.deletingLastPathComponent(), current = url.lastPathComponent
        if let problem = renameProblem(name, in: directory, current: current) { return problem }
        guard name != current else { return nil }
        let destination = directory.appendingPathComponent(name)
        if renamex_np(url.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return nil }
        let code = errno
        // APFS can report EEXIST for a case-only move of the same entry.
        // Stage exclusively, then move exclusively; no unrelated entry is overwritten.
        if code == EEXIST, name.lowercased() == current.lowercased(),
           (try? FileManager.default.contentsOfDirectory(atPath: directory.path).contains(name)) == false,
           sameItem(url, destination) {
            let staging = directory.appendingPathComponent(".agentpad-rename-" + UUID().uuidString)
            if renamex_np(url.path, staging.path, UInt32(RENAME_EXCL)) == 0 {
                if renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return nil }
                let message = String(cString: strerror(errno))
                if renamex_np(staging.path, url.path, UInt32(RENAME_EXCL)) != 0 {
                    return "Couldn't rename; the original remains at “\(staging.path)”: \(message)"
                }
                return message
            }
        }
        return "Couldn't rename “\(current)”: \(String(cString: strerror(code)))"
    }

    @MainActor
    static func report(_ failures: [Failure], editor: FileNameEdit? = nil) {
        guard !failures.isEmpty else { return }
        if let editor {
            editor.record(failures)
            if editor.isVisible { return }
        }
        for failure in failures {
            LocalFormTabs.shared.files(failure.url.deletingLastPathComponent())?.record([failure])
        }
    }
}

/// Captured again after each suspension and immediately before Trash. Directory
/// entry identity is separate because staging changes its modification time.
struct FileIdentity: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let path: String
    }
    let entry: Entry
    let size: UInt64
    let modified: Date?
    let type: String
    init?(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = attrs[.systemFileNumber] as? NSNumber, let device = attrs[.systemNumber] as? NSNumber else { return nil }
        entry = Entry(device: device.uint64Value, inode: inode.uint64Value, path: FileOperations.realPath(url))
        size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        modified = attrs[.modificationDate] as? Date
        type = (attrs[.type] as? FileAttributeType)?.rawValue ?? ""
    }
}

/// Owns the file manager used by a serial transfer. The manager has no delegate;
/// its copy/move/Trash methods run only inside that operation's async executor.
struct TransferFileIO: @unchecked Sendable {
    let manager: FileManager
    init(_ manager: FileManager = FileManager()) { self.manager = manager }
}
