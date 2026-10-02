import Darwin
import Foundation

/// kqueue watcher on a single directory. Fires `onChange` (debounced ~200ms)
/// when entries are created, deleted, or renamed inside it — a directory's
/// vnode gets a `.write` event whenever its entry list mutates — and when the
/// directory itself is deleted or renamed. The generic sibling of
/// `GitWatcher`, which is hardwired to `.git/HEAD` + `.git/index`; the
/// sidebar file tree keeps one of these per visible (root or expanded)
/// directory.
@MainActor
final class DirectoryWatcher {
    let directory: URL
    private var source: DispatchSourceFileSystemObject?
    private var pendingRefresh: DispatchWorkItem?
    /// Set by `cancel()` so the deferred re-attach (below) can't resurrect a
    /// watcher the owner already dropped — that fd would leak with nobody
    /// left to close it. GitWatcher gets the same guard from its
    /// `watchedCwd` nil-check.
    private var isCancelled = false
    private let onChange: () -> Void

    init(directory: URL, onChange: @escaping () -> Void) {
        self.directory = directory
        self.onChange = onChange
    }
    // No deinit cleanup — `@MainActor` deinits run nonisolated in Swift 6, and
    // the project convention (see GitWatcher) is to require explicit teardown.
    // Callers MUST invoke `cancel()` before dropping the watcher, or kqueue
    // fds leak.

    /// Idempotent for a live watcher; the rebuild path (after the directory
    /// was atomically replaced) falls through because `source` is nil there.
    func start() {
        guard source == nil else { return }
        isCancelled = false
        attach()
    }

    func cancel() {
        isCancelled = true
        source?.cancel()
        source = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    private func attach() {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            // Directory missing (deleted-then-recreated later, or not yet
            // created). A one-shot retry strands the watcher dead forever —
            // in the file tree's rootError state this is the ONLY live
            // recovery path — so poll gently until the path returns or the
            // owner cancels.
            scheduleReattach(after: 0.5)
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            // Identity guard: GCD still delivers already-enqueued invocations
            // after cancel(), so a stale event from a replaced source must
            // not act on — and cancel — the healthy current one.
            guard let self, self.source === src else { return }
            let data = src.data
            self.scheduleRefresh()
            // `.delete`/`.rename` mean our fd's vnode is going away (rm -r,
            // mv, or an atomic directory swap). Drop the source and try to
            // re-attach to whatever now sits at the same path — if nothing
            // does yet, `attach` keeps retrying until the path returns or
            // the owner cancels.
            if data.contains(.delete) || data.contains(.rename) {
                self.source?.cancel()
                self.source = nil
                self.scheduleReattach(after: 0.05)
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    /// Deferred re-attach for a path whose vnode went away. Retries until
    /// `attach` succeeds or the owner cancels; on success fires a refresh so
    /// the model re-lists what now sits at the path (the fresh fd only
    /// reports *future* changes).
    private func scheduleReattach(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isCancelled, self.source == nil else { return }
            self.attach()
            if self.source != nil { self.scheduleRefresh() }
        }
    }

    private func scheduleRefresh() {
        // Bulk operations (git checkout, npm install, rm -r) touch a
        // directory many times in quick succession; coalesce into one
        // re-list.
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
