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
        if trimmed.contains("/") || trimmed.contains(":") { return "The name can't contain “/” or “:”." }
        if trimmed == "." || trimmed == ".." { return "That name is reserved." }
        if trimmed == current { return nil }
        // A case-only rename on a case-insensitive volume finds "itself".
        if let current, trimmed.lowercased() == current.lowercased() { return nil }
        if exists(directory.appendingPathComponent(trimmed)) { return "“\(trimmed)” already exists here." }
        return nil
    }

    // MARK: Pasteboard

    /// What a paste would do with the pasteboard's files.
    enum PasteMode: Equatable { case copy, move }

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

    struct TransferResult: Equatable, Sendable {
        var done: [URL] = []
        /// Sources that were copied/moved (for keeping a partial cut alive).
        var doneSources: [URL] = []
        var skipped: [URL] = []
        var failures: [String] = []
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
        fileManager: FileManager = .default,
        resolve: (URL) -> ConflictChoice
    ) -> TransferResult {
        var result = TransferResult()
        let exists: (URL) -> Bool = { (try? fileManager.attributesOfItem(atPath: $0.path)) != nil }
        let dir = directory.standardizedFileURL
        let realDir = realPath(dir)
        let realSources = sources.map(realPath)
        for source in sources.map(\.standardizedFileURL) {
            let realSource = realPath(source)
            // A folder into itself or its own subfolder would recurse forever.
            if isInside(realDir, realSource) {
                result.failures.append("Can't put “\(source.lastPathComponent)” inside itself.")
                continue
            }
            var destination = dir.appendingPathComponent(source.lastPathComponent)
            var replacing: URL?
            if exists(destination) {
                if sameItem(destination, source) {
                    // Pasting onto itself: Finder makes a copy; a move is a no-op.
                    if mode == .move { result.skipped.append(source); continue }
                    destination = duplicateURL(for: source, exists: exists)
                } else {
                    switch resolve(destination) {
                    case .stop:
                        result.skipped.append(source)
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
                            result.failures.append("Can't replace “\(destination.lastPathComponent)”: it contains an item being moved.")
                            continue
                        }
                        replacing = destination
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
                result.failures.append("“\(source.lastPathComponent)”: \(error.localizedDescription)")
                continue
            }
            if let replacing {
                /// Undo the staged copy/move; reports if even that fails.
                func unstage() {
                    do {
                        if mode == .move { try fileManager.moveItem(at: target, to: source) }
                        else { try fileManager.removeItem(at: target) }
                    } catch {
                        result.failures.append("The new “\(source.lastPathComponent)” was left as “\(target.lastPathComponent)”: \(error.localizedDescription)")
                    }
                }
                var trashed: NSURL?
                do {
                    try fileManager.trashItem(at: replacing, resultingItemURL: &trashed)
                } catch {
                    unstage()
                    result.failures.append("Couldn't replace “\(replacing.lastPathComponent)”: \(error.localizedDescription)")
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
                    result.failures.append(restored
                        ? "Couldn't replace “\(replacing.lastPathComponent)”; it was left unchanged: \(error.localizedDescription)"
                        : "Couldn't replace “\(replacing.lastPathComponent)”; the original is in the Trash: \(error.localizedDescription)")
                    continue
                }
            }
            result.done.append(destination)
            result.doneSources.append(source)
        }
        return result
    }

    /// Pastes the general pasteboard into `directory`, asking about clashes.
    /// The file work runs off the main thread; only the dialogs come back to it.
    @MainActor
    static func paste(into directory: URL) {
        let sources = pasteboardFiles()
        guard !sources.isEmpty else { return }
        let mode = pasteMode()
        let changeCountAtStart = NSPasteboard.general.changeCount
        Task { @MainActor in
            let result = await transferInBackground(sources, into: directory, mode: mode)
            // Only touch the clipboard if nobody copied something else meanwhile.
            if mode == .move, NSPasteboard.general.changeCount == changeCountAtStart {
                // Whatever didn't move stays cut, so pasting again finishes the job.
                let moved = Set(result.doneSources.map(\.path))
                let remaining = sources.filter { !moved.contains($0.standardizedFileURL.path) }
                if remaining.isEmpty { pendingCut = nil } else { copy(remaining, cut: true) }
            }
            report(result.failures)
        }
    }

    /// `transfer` on a background thread, asking clash questions on the main
    /// thread (with an "Apply to all" box when there's more than one item).
    @MainActor
    static func transferInBackground(_ sources: [URL], into directory: URL, mode: PasteMode) async -> TransferResult {
        let more = sources.count > 1
        return await Task.detached(priority: .userInitiated) {
            var applyToAll: ConflictChoice?
            return transfer(sources, into: directory, mode: mode) { clash in
                if let applyToAll { return applyToAll }
                let (choice, all) = DispatchQueue.main.sync {
                    MainActor.assumeIsolated { askAboutConflict(clash, more: more) }
                }
                if all { applyToAll = choice }
                return choice
            }
        }.value
    }

    // MARK: Single-item operations

    @MainActor
    static func trash(_ urls: [URL]) {
        Task { @MainActor in
            let failures = await Task.detached(priority: .userInitiated) { () -> [String] in
                var failures: [String] = []
                for url in urls {
                    do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                    catch { failures.append("“\(url.lastPathComponent)”: \(error.localizedDescription)") }
                }
                return failures
            }.value
            report(failures)
        }
    }

    @MainActor
    static func duplicate(_ url: URL) {
        Task { @MainActor in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try FileManager.default.copyItem(at: url, to: duplicateURL(for: url)); return nil }
                catch { return "“\(url.lastPathComponent)”: \(error.localizedDescription)" }
            }.value
            report(failure.map { [$0] } ?? [])
        }
    }

    /// Creates `untitled folder` (or `untitled folder 2`…) and returns it.
    @MainActor
    @discardableResult
    static func newFolder(in directory: URL) -> URL? {
        let url = uniqueURL(for: directory.appendingPathComponent("untitled folder"))
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        } catch {
            report([error.localizedDescription])
            return nil
        }
    }

    /// Asks for a name, then creates an empty file with it.
    @MainActor
    static func newFile(in directory: URL) {
        guard let name = askForName(title: "New File", message: "Name for the new file:", initial: "untitled.txt", directory: directory, current: nil) else { return }
        let url = directory.appendingPathComponent(name)
        if let problem = createExclusively(url) { report([problem]) }
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
    static func rename(_ url: URL) {
        let current = url.lastPathComponent
        guard let name = askForName(title: "Rename", message: "New name for “\(current)”:", initial: current, directory: url.deletingLastPathComponent(), current: current),
              name != current
        else { return }
        do { try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent(name)) }
        catch { report(["Couldn't rename “\(current)”: \(error.localizedDescription)"]) }
    }

    // MARK: Dialogs

    @MainActor
    private static func askForName(title: String, message: String, initial: String, directory: URL, current: String?) -> String? {
        var text = initial
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            let field = NSTextField(string: text)
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            alert.window.initialFirstResponder = field
            // Select the base name, not the extension — Finder's habit.
            let base = split(text).base
            DispatchQueue.main.async {
                field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
            }
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            text = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let problem = renameProblem(text, in: directory, current: current) else { return text }
            report([problem])
        }
    }

    @MainActor
    static func askAboutConflict(_ clash: URL, more: Bool) -> (ConflictChoice, Bool) {
        let alert = NSAlert()
        alert.messageText = "“\(clash.lastPathComponent)” already exists here."
        alert.informativeText = "Replacing moves the existing item to the Trash."
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        if more {
            alert.addButton(withTitle: "Stop")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Apply to all"
        }
        NSApp.activate()
        let attentionID = UUID()
        PendingConfirmations.shared.register(attentionID, window: alert.window)
        defer { PendingConfirmations.shared.end(attentionID) }
        let choice: ConflictChoice
        switch alert.runModal() {
        case .alertFirstButtonReturn: choice = .keepBoth
        case .alertSecondButtonReturn: choice = .replace
        case .alertThirdButtonReturn: choice = .skip
        default: choice = .stop
        }
        return (choice, alert.suppressionButton?.state == .on)
    }

    @MainActor
    static func report(_ failures: [String]) {
        guard !failures.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failures.count == 1 ? "The operation didn't complete" : "Some items didn't complete"
        alert.informativeText = failures.prefix(8).joined(separator: "\n")
        NSApp.activate()
        alert.runModal()
    }
}
