import AppKit

extension Array {
    /// Step `direction` from `current`, wrapping at both ends. Used by tab
    /// and pane cycling. Direction can be any non-zero `Int`; positive walks
    /// forward, negative walks backward. Returns 0 for an empty array so
    /// callers can index without bounds checks (subscripting into an empty
    /// array would still trap, so guard `!isEmpty` before subscripting).
    func cyclicIndex(from current: Int, step direction: Int) -> Int {
        guard !isEmpty else { return 0 }
        return ((current + direction) % count + count) % count
    }
}

/// True iff `url` points at a directory that currently exists on disk.
func isDirectory(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

/// Returns `path` as a directory URL if it exists, otherwise the user's
/// home dir. The fallback prevents AgentPad from spawning a shell at a deleted
/// project path (deleted between sessions, externally unmounted disk),
/// which manifests as the new tab dying with a confusing one-line error.
func resolvedSpawnCwd(_ path: String) -> URL {
    let url = URL(fileURLWithPath: path)
    return isDirectory(url) ? url : URL(fileURLWithPath: NSHomeDirectory())
}

/// AgentPad's one canonical form for on-disk path identity: shells report the
/// LOGICAL cwd, workspaces may hold either spelling, so equality checks must
/// resolve symlinks (`/tmp` vs `/private/tmp`) before comparing. Shared by
/// the file tree's re-rooting and the CLI's workspace matching — a drift
/// here is "opening the same project stacks new workspaces".
func canonicalDiskPath(_ url: URL) -> URL {
    url.resolvingSymlinksInPath().standardizedFileURL
}

/// "`path` is `root` or lies inside it", on already-standardized absolute
/// paths. The sibling trap (`/a/bc` is not inside `/a/b`) lives here once;
/// so does the root-of-the-disk case, which the prefix form alone would
/// spell as `//`.
func pathIsInside(_ path: String, root: String) -> Bool {
    root == "/" ? path.hasPrefix("/") : path == root || path.hasPrefix(root + "/")
}

/// macOS keeps `/tmp`, `/var`, `/etc` as symlinks into `/private`. Foundation
/// strips that prefix when it resolves a path; the kernel's `getcwd` — what
/// an agent records — keeps it. The other spelling of a path under those
/// dirs, nil elsewhere.
func privateSpelling(of path: String) -> String? {
    ["/tmp", "/var", "/etc"].contains { pathIsInside(path, root: $0) } ? "/private" + path : nil
}

/// Trims a title string; blank or whitespace-only input collapses to `nil`.
/// Shared by the manual-rename paths and the OSC-title observer so "empty
/// means no title" stays one rule.
func normalizedTitle(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// `NSHomeDirectory()` re-resolves through Foundation on every call and cannot
/// change while the process lives. `Session.title` and `Workspace.title` both
/// compare against it, and those run on every sidebar / agent-panel row render,
/// so resolve it once — it was the single largest cost in either title.
let homeDirectoryPath = NSHomeDirectory()

/// Flattens a value that is about to become ONE line of a newline-joined
/// string. Titles arrive from OSC sequences and from hand-written
/// settings.json, and `normalizedTitle` only trims the ends — an interior
/// newline survives it. Every other render site is a `Text(...).lineLimit(1)`
/// that collapses newlines on its own; a tooltip whose line count carries
/// meaning is the one place that has to do it explicitly.
func singleLine(_ raw: String) -> String {
    raw.split(whereSeparator: \.isNewline)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
}

/// Three-state sidebar visibility. `next` cycles full → compact → hidden →
/// full so each toggle hides more and eventually wraps around.
enum SidebarMode: String, Codable, Equatable, Sendable {
    case full
    case compact
    case hidden

    var next: SidebarMode {
        switch self {
        case .full: return .compact
        case .compact: return .hidden
        case .hidden: return .full
        }
    }
}

/// What the left sidebar's middle area shows — the workspace list or the
/// active workspace's file tree. The footer toggle switches between them;
/// the brand header and footer stay visible in both.
enum SidebarContent: String, Codable, Equatable, Sendable {
    case workspaces
    case files
    /// AgentPad: team calls received and sent (Team/TeamCallsSidebar.swift).
    case team
    case chat
}

/// What the right sidebar shows in full mode — live agents, on-disk history,
/// or details for the active tab. Mirrors `SidebarContent`'s footer-toggle
/// model. Compact mode always renders agents: a 44pt icon rail can't express
/// either of the detail pages usefully.
enum RightSidebarContent: String, Codable, Equatable, Sendable, CaseIterable {
    case agents
    case history
    case info
}

@MainActor
@Observable
final class WorkspaceStore {
    let agentProfiles: AgentProfileStore
    var expandedAgentProfiles: Set<UUID> = []
    var revealedAgentProfileID: UUID?
    var agentProfileRevealRevision = 0
    var profileHistoryLimits: [UUID: Int] = [:]
    @ObservationIgnored var lastProfileActivation: (id: UUID, time: TimeInterval)?
    var agentProfileErrors: [UUID: String] = [:]
    @ObservationIgnored var profileTemplates: () -> [AgentTemplate] = { AgentTemplate.all }
    var profileStores: [WorkspaceStore] { ([self] + peerStores().filter { $0 !== self }).filter { !$0.isTerminated } }

    func revealAgentProfile(_ id: UUID) {
        expandedAgentProfiles.insert(id)
        revealedAgentProfileID = id
        agentProfileRevealRevision += 1
        setSidebarMode(.full)
        setSidebarContent(.chat)
    }

    private(set) var workspaces: [Workspace] = []
    private(set) var activeWorkspaceId: UUID?
    /// Session id currently being dragged in any pane's tab bar. Shared across
    /// all `TabBarView` instances so target panes can show drop indicators
    /// even when the source lives in a different pane.
    var draggingTabId: UUID?
    /// Shared with peer windows so every sidebar can identify a tab drag.
    var draggedTab: Session? {
        for owner in [self] + peerStores().filter({ $0 !== self }) {
            if let id = owner.draggingTabId, let session = owner.findSession(id: id) { return session }
        }
        return nil
    }
    var leftNavigation = LeftNavigationPreferences()
    var navigationPresentation = LeftNavigationPresentation()
    @ObservationIgnored var navigationDragTargets: Set<String> = []
    @ObservationIgnored var navigationDragExit: Task<Void, Never>?
    @ObservationIgnored weak var navigationWindow: NSWindow?
    @ObservationIgnored weak var navigationReturnResponder: NSResponder?
    /// Compatibility for existing callers; new UI uses the independent preferences.
    var sidebarMode: SidebarMode {
        get { leftNavigation.legacyMode }
        set { leftNavigation = .migrate(mode: newValue, content: sidebarContent) }
    }
    /// Right-side agent-overview sidebar — per-window collapse state, sharing
    /// the left sidebar's three modes (full / compact / hidden). The content is
    /// the global `AgentMonitor`; each window toggles its own panel. Defaults
    /// to hidden since it's opt-in.
    var rightSidebarMode: SidebarMode = .hidden
    /// Compatibility entry point for existing panel navigation callers.
    var sidebarContent: SidebarContent {
        get { SidebarContent(rawValue: leftNavigation.panelContent.rawValue)! }
        set { leftNavigation.panelContent = .init(rawValue: newValue.rawValue) ?? .chat }
    }
    var chatSidebarPreferences = ChatSidebarPreferences()
    let chatNavigation = ChatSidebarNavigation()
    var attentionExpanded = false
    var sidebarDisplayWidth: CGFloat {
        sidebarContent == .chat ? CGFloat(ChatSidebarPreferences.clampWidth(chatSidebarPreferences.width)) : sidebarWidth
    }

    func setSidebarDisplayWidth(_ width: CGFloat) {
        if sidebarContent == .chat { chatSidebarPreferences.width = ChatSidebarPreferences.clampWidth(Double(width)) }
        else { sidebarWidth = SidebarView.clampWidth(width) }
    }

    func setChatSectionCollapsed(_ section: ChatSidebarPreferences.Section, _ collapsed: Bool) {
        chatSidebarPreferences.setCollapsed(section, collapsed)
        scheduleSave()
    }
    /// Right sidebar's full-mode content — live agents, history, or active
    /// session information.
    /// Persisted like `sidebarContent`; the panel's own footer toggle flips it.
    var rightSidebarContent: RightSidebarContent = .agents
    /// History pane's agent filter + search text. Runtime-only, but owned by
    /// the STORE, not the view: collapsing the panel (or cycling its mode)
    /// unmounts `SessionHistoryView`, and `@State` there would reset both to
    /// defaults on every reopen.
    var historyFilterAgentId: String?
    var historySearchQuery = ""
    /// The "only this workspace" checkbox: list only sessions that ran
    /// inside the active workspace (`historyWorkspaceRoot`). Off by default
    /// like the agent chip — it isn't persisted, and a preference that
    /// reset to ON would need re-flipping every launch.
    var historyFilterCurrentWorkspace = false
    /// The directory the checkbox would scope to, or nil when there is
    /// nothing local to scope: no workspace, or an SSH workspace (its
    /// sessions live on the remote — the local spawn dir says nothing about
    /// them). The checkbox row shows exactly when this is non-nil, so the
    /// view never restates the rule.
    var historyScopeAnchor: URL? {
        guard let workspace = active, workspace.sshRemoteHost == nil else { return nil }
        return workspace.diskPath
    }
    /// The root the History pane filters by while the checkbox is on, else
    /// nil: git's own answer for the anchor — the working-tree root above
    /// its PHYSICAL path. Physical because git resolves cwd with `getcwd`,
    /// so a symlink INTO a repo (`~/alias -> ~/repo/src`) belongs to
    /// `~/repo` even though nothing above `~/alias` holds a `.git`. NOT the
    /// anchor itself: `workingDirectory` follows the active tab's `cd`, so a
    /// session launched at the project root would vanish the moment the
    /// user cd's into `src/`. Outside any repo the workspace dir is the best
    /// root there is. Not `gitStatus.repoRoot`: that is nil until a tab's
    /// first prompt fetch lands (a restored tab may not have spawned yet)
    /// and one prompt stale across a `cd` between repos.
    var historyWorkspaceRoot: URL? {
        guard historyFilterCurrentWorkspace, let anchor = historyScopeAnchor else { return nil }
        let physical = canonicalDiskPath(anchor)
        return GitWatcher.worktreeRoot(near: physical) ?? physical
    }
    /// `historyWorkspaceRoot` in every spelling a record's cwd may carry.
    /// Most agents record the physical cwd, but Go's `os.Getwd` (Reasonix)
    /// keeps the shell's LOGICAL `$PWD`, and the kernel keeps `/private`
    /// where Foundation strips it — so beside the root itself: the logical
    /// walk's root when it resolves to the same directory (a symlink ABOVE
    /// the root, `~/code -> /Volumes/Dev/code`), the anchor's own logical
    /// path (inside the root by construction, and the only logical spelling
    /// a symlink INTO a repo has), and the `/private` form. Only roots are
    /// resolved — resolving every record would stat paths on volumes long
    /// gone. Empty when not filtering.
    var historyWorkspaceRootPaths: [String] {
        guard let root = historyWorkspaceRoot, let anchor = historyScopeAnchor else { return [] }
        var paths = [root.path]
        func add(_ path: String) {
            if !paths.contains(where: { pathIsInside(path, root: $0) }) { paths.append(path) }
        }
        if let logicalRoot = GitWatcher.worktreeRoot(near: anchor),
           canonicalDiskPath(logicalRoot).path == root.path {
            add(logicalRoot.standardizedFileURL.path)
        }
        add(anchor.standardizedFileURL.path)
        for path in paths { if let kernel = privateSpelling(of: path) { add(kernel) } }
        return paths
    }
    /// Session Info's collapsed sections, keyed by section title. Owned by the
    /// store for exactly the reason above — the page unmounts whenever the
    /// panel switches, so `@State` in the view would forget every collapse the
    /// moment the user glanced at the agents list. Persisted per window, so a
    /// habitual "Processes stays folded" survives a relaunch too.
    ///
    /// Empty by default: every section opens, and collapsing is the user's
    /// call to make (and keep).
    var collapsedInfoSections: Set<String> = []

    func toggleInfoSection(_ title: String) {
        if collapsedInfoSections.contains(title) {
            collapsedInfoSections.remove(title)
        } else {
            collapsedInfoSections.insert(title)
        }
        scheduleSave()
    }

    /// Full-mode sidebar width, user-draggable from the trailing edge.
    /// `SidebarView.fullWidth` is the floor (the design width — the sidebar
    /// can only grow); compact stays fixed at `compactWidth` and hidden is
    /// hidden, so this only applies while expanded. Persisted per window.
    var sidebarWidth: CGFloat = LeftNavigationLayout.defaultPanelWidth

    /// Full-mode right panel (Agent Panel) width, user-draggable from its
    /// leading edge. `AgentOverviewSidebar.fullWidth` is the floor (the
    /// design width — the panel can only grow); compact stays fixed at
    /// `compactWidth` and hidden is hidden, so this only applies while
    /// expanded. Persisted per window.
    var rightSidebarWidth: CGFloat = AgentOverviewSidebar.fullWidth

    /// True while a sidebar resize drag is in flight (either side). The
    /// terminal engines suspend size propagation until the drag ends, avoiding
    /// a SIGWINCH storm while SwiftUI updates the live frame.
    var isSidebarResizing = false

    func beginSidebarResize() {
        isSidebarResizing = true
        scheduleSave()
    }

    func endSidebarResize() {
        isSidebarResizing = false
        scheduleSave()
    }
    /// File-tree state for the sidebar's files mode. Store-owned (not view
    /// `@State`) because it holds kqueue fds needing explicit teardown and
    /// the sidebar unmounts whole while hidden — `terminate()` is the
    /// window-close backstop, `FileTreeView` pauses it via on(Dis)appear.
    let fileTree = FileTreeModel()
    /// A diff-pill reveal temporarily roots the tree at that session's repo
    /// instead of its cwd, so every repo-wide diff row is representable. Tied
    /// to workspace + session identity; switching the sidebar away from files
    /// or moving focus to another workspace/tab clears it and restores the
    /// usual `Workspace.diskPath` behavior.
    private struct FileTreeRootOverride {
        let workspaceId: UUID
        let sessionId: UUID
        let root: URL
    }
    private var fileTreeRootOverride: FileTreeRootOverride?

    func navigationPanelChanged(to panel: LeftNavigationPreferences.Panel) {
        if panel != leftNavigation.panelContent, panel != .files, fileTreeRootOverride != nil { fileTreeRootOverride = nil }
    }

    /// Drops a root override that no longer matches the active workspace +
    /// session, so a later re-activation of that session can't resurrect it.
    /// Call after ANY direct active-identity write that bypasses
    /// `activateTab`/`focusPane` — same scattered-sites contract as
    /// `zoomedPaneId` (CLAUDE.md): addTab, close-collapse, cross-pane move,
    /// zoom-button focus, split.
    private func invalidateStaleFileTreeRootOverride() {
        guard let override = fileTreeRootOverride else { return }
        if override.workspaceId != active?.id
            || override.sessionId != active?.activeSession?.id {
            fileTreeRootOverride = nil
        }
    }

    var fileTreeRoot: URL? {
        guard let override = fileTreeRootOverride,
              override.workspaceId == active?.id,
              override.sessionId == active?.activeSession?.id else {
            return active?.diskPath
        }
        return override.root
    }
    /// Fired when the last workspace closes. `AgentPadWindowController` wires
    /// this to close its window — a window with zero workspaces is empty.
    var onBecameEmpty: (() -> Void)?

    /// Legacy callers can still reveal a panel; new commands toggle each
    /// surface independently and change widths without animation.
    func setSidebarMode(_ mode: SidebarMode) {
        if mode == .full { selectNavigationPanel(leftNavigation.panelContent, toggle: false) }
        else {
            closeNavigation()
            leftNavigation.panelVisible = false
            leftNavigation.railVisible = mode == .compact
            scheduleSave()
        }
    }

    func setRightSidebarMode(_ mode: SidebarMode) {
        guard rightSidebarMode != mode else { return }
        suspendSizePropagationForLayoutAnimation(active?.root.allEngines ?? [])
        rightSidebarMode = mode
        scheduleSave()
    }

    /// Content-only swap like `setSidebarContent` — the panel keeps its width,
    /// so no size-propagation suspension is needed.
    func setRightSidebarContent(_ content: RightSidebarContent) {
        guard rightSidebarContent != content else { return }
        rightSidebarContent = content
        scheduleSave()
    }

    /// Workspaces opens the temporary list; other routes reveal their panel.
    func setSidebarContent(_ content: SidebarContent) {
        if content == .workspaces { openWorkspaceList(); return }
        selectNavigationPanel(.init(rawValue: content.rawValue) ?? .chat, toggle: false)
    }

    func requestRenameActiveTab() {
        guard let session = active?.activeSession, session.hasProcess else { return }
        session.nameEdit.begin(session.customTitle ?? session.title)
    }

    func requestRenameActiveWorkspace() {
        guard let workspace = active else { return }
        requestRenameWorkspace(workspace)
    }

    /// Diff pill popover's "Show in File Tree": switch the sidebar to files
    /// mode, first promoting a hidden/compact sidebar to full — the tree
    /// only mounts in the full sidebar (`SidebarView.fileTreeIsMounted`).
    func revealFileTree(root: URL? = nil) {
        if let root, let workspace = active, let session = workspace.activeSession {
            fileTreeRootOverride = FileTreeRootOverride(
                workspaceId: workspace.id,
                sessionId: session.id,
                root: root
            )
        } else {
            fileTreeRootOverride = nil
        }
        setSidebarMode(.full)
        setSidebarContent(.files)
    }

    private let engineFactory: @MainActor () -> any TerminalEngine
    /// Resolves per-agent launch options at spawn time. Production wires this
    /// to `AgentPadSettingsModel.shared.agentOptions[id]`; tests pass a closure
    /// that returns nil so unit tests stay independent of the developer's
    /// real `~/.agentpad/settings.json`.
    let optionsProvider: @MainActor (String) -> String?
    var conversationVisibility: () -> ChannelConversationFilter = { .current() }
    var claudeProjectsRoot: URL
    /// Reads `AgentPadSettingsModel.shared.resumeConversations` at spawn time;
    /// tests inject a static value (typically `true`) for the same reason
    /// as `optionsProvider`.
    private let resumeProvider: @MainActor () -> Bool
    /// Every live window's store (including this one) — injected by
    /// `AppDelegate` so a tab dropped here from another window can be located
    /// in the store it came from. Tests default to `{ [] }`, keeping each
    /// store window-isolated.
    private let peerStores: @MainActor () -> [WorkspaceStore]
    /// Invoked when the user picks "Move to New Window" from a tab's
    /// right-click menu — `AppDelegate` opens a fresh window and moves the
    /// session into it. Tests default to a no-op.
    private let moveToNewWindow: @MainActor (UUID) -> Void
    /// Fired when a session enters an attention (waiting-on-you) state or a
    /// command there fails. `AppDelegate` decides whether to surface a system
    /// notification — only when the originating tab isn't currently visible.
    /// Tests default to a no-op.
    private let onSessionAlert: @MainActor (UUID, SessionAlertKind) -> Void
    private let onSessionWaitingEnded: @MainActor (UUID) -> Void
    /// Reports a user-chosen project folder for File → Open Recent / ⌘P.
    /// Defaults to a no-op like the other side-effecting callbacks
    /// (`onSessionAlert`, `moveToNewWindow`) — a write must never be the
    /// default a test construction silently inherits; `AppDelegate.addWindow`
    /// wires the real `RecentFolders` sink.
    private let noteRecentFolder: @MainActor (URL) -> Void
    @ObservationIgnored var searchModel: EverywhereSearchModel?
    let windowID: UUID
    let drafts: DraftRepository
    let tabCloseCoordinator: TabCloseCoordinator
    private(set) var persistenceError: String?
    private let persistence: any Persistence
    private let gitStatusFetcher = GitStatusFetcher()
    /// One watcher per session — refreshes git status when `.git/HEAD` or
    /// `.git/index` changes from any source (agent subprocess, external
    /// terminal, file-level git ops). The OSC 7 / OSC 133 paths only see
    /// the outer shell, so an agent running its own subprocess shell never
    /// trips them; the filesystem layer catches everyone.
    ///
    /// One watcher per RESOLVED gitdir, shared by every session whose cwd
    /// lives in that repo. `findGitDir` resolves a worktree's `.git` pointer
    /// file to its own `.git/worktrees/<name>/`, so two worktrees of one
    /// repo never share an entry — their HEAD/index events can't cross-
    /// pollinate. Replaces per-session watchers: ten same-repo tabs used to
    /// mean ten fd pairs and, on one commit, ten independent debounces each
    /// forking its own git pair (fork storm + GCD worker pileup).
    /// Reference type on purpose: subscriber mutation is in-place, and the
    /// watcher + subscriber set live and die together under one key.
    private final class GitWatch {
        let watcher: GitWatcher
        var subscribers: Set<UUID> = []
        /// Prompt/spawn bursts from same-repo tabs collapse into one shared
        /// status fetch. The watcher already debounces disk events; this task
        /// covers UI-originated triggers that otherwise arrive per session.
        var pendingStatusRefresh: Task<Void, Never>?
        init(watcher: GitWatcher) { self.watcher = watcher }
    }
    private var gitWatches: [String: GitWatch] = [:]
    /// Slightly wider than GitStatusFetcher's 50ms same-lane coalescing
    /// window: a trigger arriving just after dispatch gets a guaranteed
    /// follow-up fetch instead of being swallowed by the previous batch.
    private static let sharedGitRefreshDelay = Duration.milliseconds(60)
    /// Per-session (cwd → resolved gitdir) cache so the per-prompt hub call
    /// skips the findGitDir directory walk while the cwd is unchanged.
    private var sessionGitWatch: [UUID: (cwdPath: String, gitDir: String?)] = [:]
    /// Watches each Codex session's rollout file and republishes its latest
    /// rate-limit usage to `Session.codexUsage` for the status-bar gauge.
    /// Codex blocks the shell while running, so the file is the only live
    /// signal — torn down alongside the git-watch subscription at every
    /// close site.
    private let codexUsageMonitor = CodexUsageMonitor()
    /// Reads Kiro's per-surface ACP recording and captures the exact id
    /// returned by `session/new`, including in the current non-hookable TUI.
    private let kiroConversationMonitor = KiroConversationMonitor()

    /// Snapshot of a closed tab's reopenable state. Workspace + pane IDs
    /// are best-effort routing — if either is gone by the time the user
    /// hits ⌘⇧T, `reopenLastClosedTab` falls back to the active workspace
    /// / pane.
    private struct ClosedTabState {
        let agent: AgentTemplate
        let cwd: URL
        let customTitle: String?
        let workspaceId: UUID
        let paneId: UUID
        /// Captured conversation id so `⌘⇧T` resumes the agent session
        /// the user just closed (subject to `resumeConversations` setting).
        let conversationId: String?
        var launchOrigin: AgentLaunchOrigin? = nil
        var profileID: UUID? = nil
        var profileOriginalCwd: URL? = nil
        /// The tab's own destination; nil means explicitly local, even if
        /// it was moved into an SSH workspace before being closed.
        let sshWorkspaceHost: String?
        // AgentPad: a closed channel tab comes back a channel tab; no title kept.
        var channel: ChannelRef? = nil
        var inbox: ChatInboxRef? = nil
        var tool: ToolRoute? = nil
        var navigation: TabNavigation? = nil
        var unavailableTab: PersistedTab? = nil
        var unavailableMessage: String? = nil
    }

    /// LIFO stack of recently-closed tabs for ⌘⇧T (reopen). Capped at
    /// `closedTabHistoryLimit` so a long session doesn't unbounded-grow.
    /// Runtime-only — closed tabs do not survive an app restart.
    private var recentlyClosed: [ClosedTabState] = []
    private static let closedTabHistoryLimit = 50

    private(set) var pendingSave: Task<Void, Never>?

    /// Set by `terminate()`. The window layer drops its controller only on
    /// the NEXT main-queue tick (releasing an NSWindow synchronously inside
    /// windowWillClose crashes AppKit), so for one tick a dead store is
    /// still reachable through `windowControllers` — anything that acts on
    /// a store from outside the UI (the CLI) must skip it, or it lands a tab
    /// in a store that is about to be dropped and reports success. Hook-socket
    /// ingress gates itself on it instead (`hookSession`).
    private(set) var isTerminated = false
    /// Final window/app flushes must retain the state from before any engine
    /// was stopped, even if teardown callbacks still reach the live model.
    private var terminationSnapshot: PersistedState?
    /// False while this store's window is ordered out (closed-but-alive,
    /// see `AppDelegate.shouldCloseWindow`). Sessions and agents keep
    /// running; only work that exists to paint pixels pauses — terminal
    /// rendering, git status fetches, file-tree watchers, the Session Info
    /// process poll. Not `isTerminated`: that path kills engines.
    private(set) var isOnScreen = true
    private static let saveDebounce: UInt64 = 1_000_000_000

    func setOnScreen(_ onScreen: Bool) {
        guard onScreen != isOnScreen, !isTerminated else { return }
        isOnScreen = onScreen
        if !onScreen { invalidateTabConfirmations() }
        let sessions = workspaces.flatMap { $0.root.allPanes }.flatMap(\.tabs)
        for session in sessions { session.engine.setOnScreen(onScreen) }
        if onScreen {
            fileTree.resume()
            // Everything git-related was skipped while hidden — prompts,
            // GitWatcher events, and edits from outside that touch neither
            // HEAD nor index. One fetch per session catches all of it up.
            for session in sessions { refreshGitStatus(for: session) }
        } else {
            fileTree.suspend()
        }
    }

    var active: Workspace? {
        workspaces.first { $0.id == activeWorkspaceId }
    }

    init(
        persistence: any Persistence,
        initiallyEmpty: Bool = false,
        agentProfiles: AgentProfileStore? = nil,
        drafts: DraftRepository? = nil,
        engineFactory: @escaping @MainActor () -> any TerminalEngine = { LibghosttyEngine() },
        optionsProvider: @escaping @MainActor (String) -> String? = { AgentPadSettingsModel.shared.agentOptions[$0] },
        resumeProvider: @escaping @MainActor () -> Bool = { AgentPadSettingsModel.shared.resumeConversations },
        conversationVisibility: @escaping () -> ChannelConversationFilter = { .current() },
        peerStores: @escaping @MainActor () -> [WorkspaceStore] = { [] },
        moveToNewWindow: @escaping @MainActor (UUID) -> Void = { _ in },
        onSessionAlert: @escaping @MainActor (UUID, SessionAlertKind) -> Void = { _, _ in },
        onSessionWaitingEnded: @escaping @MainActor (UUID) -> Void = { _ in },
        noteRecentFolder: @escaping @MainActor (URL) -> Void = { _ in },
        claudeProjectsRoot: URL = ClaudeSessionResume.projectsRoot(),
        codexSessionsRoot: URL = CodexUsageMonitor.defaultSessionsRoot()
    ) {
        self.persistence = persistence
        // Test windows use isolated profile stores unless their fixture explicitly shares one.
        self.agentProfiles = agentProfiles ?? (NSClassFromString("XCTestCase") == nil ? .shared : AgentProfileStore())
        self.windowID = (persistence as? WindowPersistence)?.windowId ?? UUID()
        let repository = drafts ?? (persistence as? WindowPersistence)?.app.drafts ?? DraftRepository()
        self.drafts = repository
        self.tabCloseCoordinator = TabCloseCoordinator(drafts: repository)
        self.engineFactory = engineFactory
        self.optionsProvider = optionsProvider
        self.resumeProvider = resumeProvider
        self.conversationVisibility = conversationVisibility
        self.peerStores = peerStores
        self.moveToNewWindow = moveToNewWindow
        self.onSessionAlert = onSessionAlert
        self.onSessionWaitingEnded = onSessionWaitingEnded
        self.noteRecentFolder = noteRecentFolder
        self.claudeProjectsRoot = claudeProjectsRoot
        if var saved = persistence.load(), !saved.workspaces.isEmpty {
            if saved.agentTabRepair119Applied != true {
                AgentTabRepair.apply(to: &saved, claudeProjectsRoot: claudeProjectsRoot,
                                     codexSessionsRoot: codexSessionsRoot, visibility: conversationVisibility())
                // Commit both repairs and the marker before any engines start.
                // A missing transcript must not trigger another search next launch.
                do { try persistence.saveChecked(saved) }
                catch { persistenceError = error.localizedDescription }
            }
            restore(from: saved)
        } else if initiallyEmpty {
            addEmptyWorkspace()
        } else {
            addWorkspace()
        }
    }

    @discardableResult
    func addEmptyWorkspace() -> Workspace {
        invalidateTabConfirmations()
        let workspace = Workspace(workingDirectory: URL(fileURLWithPath: homeDirectoryPath), root: PaneNode(pane: Pane()))
        workspaces.append(workspace); activeWorkspaceId = workspace.id
        scheduleSave()
        return workspace
    }

    var allSessions: [Session] { workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) } }
    func invalidateTabConfirmations() {
        for session in allSessions {
            session.terminalConfirmation.invalidate()
            session.tabState?.confirmation.invalidate()
            session.tabState?.fileOperation?.stopIfWaiting()
            (session.engine as? ChannelTabEngine)?.conversation.confirmation.invalidate()
        }
    }

    @discardableResult
    func openToolTab(_ route: ToolRoute, navigation: TabNavigation = TabNavigation()) -> Session {
        // Reopen/duplicate enter here without the router. Connection still
        // has one login flow across every window, including hidden windows.
        let owners = route == .connection ? [self] + peerStores().filter { $0 !== self } : [self]
        for owner in owners where !owner.isTerminated {
            if let existing = owner.allSessions.first(where: { $0.toolRoute?.key(windowID: owner.windowID) == route.key(windowID: windowID) }),
               let location = owner.location(ofSessionId: existing.id) {
                location.workspace.zoomedPaneId = nil
                owner.activateWorkspace(location.workspace); owner.activateTab(existing, in: location.workspace)
                if owner !== self { TabRouter.shared.revealWindow(owner) }
                return existing
            }
        }
        let workspace = active ?? addEmptyWorkspace()
        let pane = workspace.activePane ?? workspace.root.firstPane!
        let session = makeToolSession(route, navigation: navigation, cwd: workspace.workingDirectory)
        attachSession(session, to: pane, at: pane.tabs.count, in: workspace)
        return session
    }

    /// A successful create-channel keeps the tab instance and replaces only
    /// its native content. The old state's late callbacks are now invalid.
    func replaceToolWithChannel(_ session: Session, ref: ChannelRef) {
        guard session.toolRoute != nil, location(ofSessionId: session.id) != nil else { return }
        session.engine.view.removeFromSuperview()
        session.engine.terminate()
        session.engine = ChannelTabEngine(ref: ref)
        session.content = .channel(ref)
        holdChannelClose(session)
        scheduleSave()
    }

    private func makeToolSession(_ route: ToolRoute, id: UUID = UUID(), navigation: TabNavigation = TabNavigation(), cwd: URL) -> Session {
        var navigation = navigation
        let recovered = navigation.draftID.flatMap(drafts.draft) ?? drafts.drafts
            .filter { $0.route.key(windowID: windowID) == route.key(windowID: windowID) }
            .max { $0.revision < $1.revision }
        if let recovered { navigation.draftID = recovered.id }
        let state = TabState(route: route, navigation: navigation)
        state.draft = recovered
        if case .unavailable = route { state.message = "This saved tab is damaged or belongs to a newer version. Other tabs are still available." }
        if navigation.draftID != nil, recovered == nil { state.saveError = "The saved draft could not be loaded." }
        let engine = NativeTabEngine(state: state, tabID: id)
        let session = Session(id: id, engine: engine, currentDirectory: cwd, agent: .terminal)
        session.content = .tool(route)
        holdChannelClose(session)
        return session
    }

    // MARK: - Workspaces

    @discardableResult
    func addWorkspace(
        workingDirectory: URL? = nil,
        worktreeParent: Workspace? = nil,
        worktreeBranch: String? = nil,
        template: AgentTemplate = .terminal,
        sshRemoteHost: String? = nil,
        conversationId: String? = nil,
        forceResume: Bool = false,
        claudeResolution: Result<String, ClaudeSessionResume.Refusal>? = nil,
        rawLaunchCommand: String? = nil,
        customTitle: String? = nil,
        activate: Bool = true,
        spawnInBackground: Bool = false
    ) -> Workspace {
        // NB: the home fallback (fresh window's seed workspace) reaching
        // `noteRecentFolder` below is caught by `RecentFolders.note()`'s own
        // home exclusion — if this fallback ever becomes a configurable
        // default-projects dir, the recent list starts recording it silently.
        // `inheritedFrom` is captured HERE, before `activeWorkspaceId` moves
        // to the new workspace below — `active` later means the new one.
        let inheritedFrom = workingDirectory == nil ? active : nil
        let dir = workingDirectory
            ?? inheritedFrom?.workingDirectory
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let pane = Pane()
        let root = PaneNode(pane: pane)
        let workspace = Workspace(workingDirectory: dir, root: root)
        workspace.worktreeParentId = worktreeParent?.id
        workspace.worktreeBranch = worktreeBranch
        workspace.sshRemoteHost = Self.normalizedSSHHost(sshRemoteHost)
        // Pin worktreePath at create time so `git worktree remove` always
        // targets the disk root, no matter where the user cd's later.
        // `.standardizedFileURL` resolves `/tmp` → `/private/tmp` etc. so
        // a later reconcile comparison against `git worktree list`
        // output (which is already realpath'd) lines up.
        if worktreeParent != nil {
            workspace.worktreePath = dir.standardizedFileURL
        }
        // A new workspace always comes up with exactly one tab. The spawn
        // arguments are forwarded so that tab can BE what the caller wanted
        // (see `localSpawn`) instead of a default shell the caller then has
        // to open a second tab beside — one `open`, one PTY.
        let session = spawnSession(
            template: template,
            initialCwd: dir,
            conversationId: conversationId,
            forceResume: forceResume,
            claudeResolution: claudeResolution,
            sshRemoteHost: workspace.sshRemoteHost,
            rawLaunchCommand: rawLaunchCommand,
            customTitle: customTitle,
            spawnInBackground: spawnInBackground
        )
        configureSession(session, in: workspace, codexRolloutId: session.resumedConversationId)
        pane.tabs.append(session)
        pane.activeTabId = session.id
        // Worktrees insert right after their source (or after the source's
        // existing worktrees) — compact-mode sidebar walks `workspaces`
        // in array order, so this visual grouping is load-bearing there.
        if let parent = worktreeParent,
           let parentIdx = workspaces.firstIndex(where: { $0 === parent }) {
            var insertAt = parentIdx + 1
            while insertAt < workspaces.count
                  && workspaces[insertAt].worktreeParentId == parent.id {
                insertAt += 1
            }
            workspaces.insert(workspace, at: insertAt)
        } else {
            workspaces.append(workspace)
        }
        if activate {
            invalidateTabConfirmations()
            activeWorkspaceId = workspace.id
        }
        // Remember the project folder for Open Recent / ⌘P (issue #28) —
        // except worktree children (their dir dies with the worktree) and
        // SSH workspaces (the local cwd is not where the project lives).
        // The exclusion follows the DIRECTORY's provenance, not just this
        // call's arguments: a dir inherited from such a workspace (⌘N with
        // one active — `inheritedFrom` — or Duplicate on one — matched by
        // path) keeps its source's exclusion.
        let origin = inheritedFrom ?? workspaces.first(where: {
            $0 !== workspace && $0.workingDirectory.standardizedFileURL.path == dir.standardizedFileURL.path
        })
        if worktreeParent == nil, workspace.sshRemoteHost == nil,
           origin?.worktreeParentId == nil, origin?.sshRemoteHost == nil {
            noteRecentFolder(dir)
        }
        scheduleAgentProfileAdoption()
        scheduleSave()
        return workspace
    }

    func requestCreateSSHWorkspace(tabs: LocalFormTabs = .shared) {
        tabs.newSSH(from: self)
    }

    func requestCreateWorktree(_ source: Workspace, tabs: LocalFormTabs = .shared) {
        tabs.newWorktree(source: source, from: self)
    }

    /// Scroll a full sidebar to the inline editor when its row is virtualized.
    var pendingRenameWorkspace: Workspace?

    /// Payload for the "close source workspace, take its worktrees with
    /// it" close review. A source can't simply close on its own — its
    /// worktrees would either show as orphan rows (the sidebar fallback)
    /// or vanish silently. Either way the user's mental model breaks.
    struct CloseSourceRequest {
        let source: Workspace
        let worktrees: [Workspace]
    }

    /// UI-level close request. Callers from the sidebar (× button, right-
    /// click menu) and the ⌘⇧W menu item both funnel here so the
    /// confirm prompt only lives in one place.
    func requestCloseWorkspace(_ workspace: Workspace) {
        if workspace.worktreeParentId != nil {
            ProcessTabs.shared.close([workspace], from: self, details: true)
            return
        }
        let worktrees = workspaces.filter { $0.worktreeParentId == workspace.id }
        if worktrees.isEmpty {
            closeWorkspace(workspace)
            return
        }
        ProcessTabs.shared.close(worktrees + [workspace], from: self)
    }

    /// Closes a fixed source/worktree set through the same batch service.
    /// `alsoDelete = true` runs `git worktree remove --force` + branch-d
    /// for each child before closing the source (the v0.18.x default
    /// behaviour, now opt-in). A failed row stays open for review. `alsoDelete = false` just
    /// drops the workspaces from the sidebar — disk untouched.
    func performCloseSource(_ request: CloseSourceRequest, alsoDelete: Bool) async -> String? {
        let batch = CloseWorkspaceBatch(targets: request.worktrees + [request.source], store: self)
        batch.alsoDelete = alsoDelete
        return await batch.execute()
    }

    /// Zombie-clean sidebar worktree workspaces against `git worktree list`.
    /// Runs once at app launch (AppDelegate calls it after every window's
    /// store is restored). Only handles the *removal* side — a sidebar
    /// entry whose worktree directory was deleted from disk (e.g. CLI
    /// `git worktree remove` while AgentPad was closed) gets dropped.
    ///
    /// v0.19.0 removed the disk → sidebar adopt path: AgentPad no longer
    /// surfaces worktrees the user created via CLI or another tool. To
    /// see them, the user explicitly goes through Create Worktree →
    /// "adopt existing worktree" mode. Reasoning: v0.18.x's auto-adopt
    /// caused noisy sidebars + scared users into not closing entries
    /// (close was destructive then). state.json + user action is now
    /// the single source of truth for what AgentPad displays.
    ///
    /// Subprocess fan-out runs off the main actor in a TaskGroup so a
    /// user with N source repos doesn't pay N × ~100ms blocked on launch.
    /// Results apply back on the main actor in source order.
    func reconcileWorktrees() async {
        // Snapshot inputs on the main actor before hopping off — Workspace
        // is @MainActor so the closure can't touch its properties from
        // background tasks.
        let inputs: [(index: Int, sourceId: UUID, cwd: URL)] = workspaces.enumerated().compactMap { index, source in
            guard source.worktreeParentId == nil else { return nil }
            return (index, source.id, source.workingDirectory)
        }
        guard !inputs.isEmpty else { return }

        let results: [(index: Int, sourceId: UUID, repoRoot: URL, infos: [WorktreeManager.Info])] = await withTaskGroup(
            of: (index: Int, sourceId: UUID, repoRoot: URL, infos: [WorktreeManager.Info])?.self
        ) { group in
            for input in inputs {
                group.addTask {
                    guard let repoRoot = WorktreeManager.repoRoot(near: input.cwd),
                          case .success(let infos) = WorktreeManager.list(repoPath: repoRoot) else {
                        return nil
                    }
                    return (input.index, input.sourceId, repoRoot, infos)
                }
            }
            var collected: [(index: Int, sourceId: UUID, repoRoot: URL, infos: [WorktreeManager.Info])] = []
            for await result in group { if let result { collected.append(result) } }
            return collected.sorted { $0.index < $1.index }
        }

        for result in results {
            guard let source = workspaces.first(where: { $0.id == result.sourceId }) else { continue }
            reconcile(source: source, sourceRoot: result.repoRoot, diskWorktrees: result.infos)
        }
    }

    /// `internal` so tests can drive it with synthetic `diskWorktrees`
    /// without spinning up a real git repo. `reconcileWorktrees` is the
    /// production entry point.
    func reconcile(source: Workspace, sourceRoot: URL? = nil, diskWorktrees: [WorktreeManager.Info]) {
        let sourceRootPath = (sourceRoot ?? WorktreeManager.repoRoot(near: source.workingDirectory) ?? source.workingDirectory)
            .standardizedFileURL
            .path
        // Drop the source workspace's own working-tree root so we're
        // comparing only sibling worktrees against the sidebar. This must
        // use a stable repo root, not `Workspace.workingDirectory`, because
        // that property follows the active shell's cwd and may be `/repo/sub`.
        let sidebar = workspaces.filter { $0.worktreeParentId == source.id }
        guard !sidebar.isEmpty else { return }

        // Precompute Set of disk satellite paths so the zombie check is
        // O(M+K) (M sidebar entries, K disk worktrees), not O(M×K) — the
        // user opens AgentPad a lot, every microsecond on this path adds up
        // to perceived launch latency.
        let satellitePaths: Set<String> = Set(
            diskWorktrees.lazy
                .map { $0.path.standardizedFileURL.path }
                .filter { $0 != sourceRootPath }
        )

        // Compare against the pinned worktreePath, not workingDirectory —
        // a sidebar row whose user cd'd to ~/Downloads still matches its
        // disk root via worktreePath. Adopt-on-discovery is deliberately
        // not handled — see method doc comment.
        for wt in sidebar where !satellitePaths.contains(wt.diskPath.standardizedFileURL.path) {
            closeWorkspace(wt)
        }
    }

    /// Runs `git worktree remove --force <path>` on a detached task. The
    /// caller closes the workspace separately — this method only touches
    /// disk. `--force` because the close review already gathered
    /// the user's intent; refusing on dirty state here would just bounce
    /// them back to terminal commands. Returns nil on success, otherwise
    /// the error message to surface in the close review.
    func removeWorktreeDirectory(_ workspace: Workspace) async -> String? {
        guard workspace.worktreeParentId != nil else {
            return "workspace is not a worktree"
        }
        let path = workspace.diskPath
        let parentDir = workspace.worktreeParentId.flatMap { parentId in
            workspaces.first(where: { $0.id == parentId })
        }?.workingDirectory
        let normalizedPath = path.standardizedFileURL.path
        // nil = removed cleanly, or nothing on disk left to delete (repo
        // root unresolvable — parent and worktree directory already gone).
        // Same shape as createWorktree: the task hands back only the
        // failure message the sheet needs.
        let failureMessage: String? = await Task.detached(priority: .userInitiated) {
            // The repoRoot probes run in here too: each is a git subprocess
            // with a 2s timeout, and this chain can run two of them — on the
            // main actor that was a worst-case 4s UI freeze right after the
            // user confirmed the remove sheet.
            let repoPath = parentDir.flatMap { WorktreeManager.repoRoot(near: $0) }
                ?? WorktreeManager.repoRoot(near: path)
                ?? (isDirectory(path) ? path : nil)
            guard let repoPath else { return nil }
            // Resolve the worktree's real current branch from `git
            // worktree list` before removing — the user may have
            // `git switch`-ed inside the worktree since AgentPad last
            // recorded `worktreeBranch`. Falling back to the stored
            // value would delete an outdated branch and leave the
            // truly-checked-out one orphaned.
            let realBranch: String? = {
                guard case .success(let infos) = WorktreeManager.list(repoPath: repoPath),
                      let match = infos.first(where: {
                          $0.path.standardizedFileURL.path == normalizedPath
                      })
                else { return nil }
                return match.branch
            }()
            if case .failure(let err) = WorktreeManager.remove(repoPath: repoPath, path: path, force: true) {
                return err.description
            }
            // Safe-delete the branch (only if merged) after the worktree
            // dir is gone — `git branch -d` would otherwise refuse with
            // "currently checked out at <path>". Failure on unmerged
            // branches is expected and intentionally ignored; the next
            // Create Worktree on the same name surfaces "branch exists
            // locally" then. No data-loss risk because git refuses to
            // drop unmerged commits without the upper-case `-D`.
            if let realBranch, !realBranch.isEmpty {
                _ = WorktreeManager.deleteBranchIfMerged(repoPath: repoPath, branch: realBranch)
            }
            return nil
        }.value
        if let failureMessage {
            return failureMessage
        }
        pruneRecentlyClosed(under: workspace)
        return nil
    }

    /// Drops `recentlyClosed` entries for a worktree workspace we just
    /// `git worktree remove`-d — without this, ⌘⇧T would respawn a tab
    /// at a deleted cwd and `resolvedSpawnCwd` would silently route it
    /// to `$HOME`, surfacing a "Terminal at ~" the user never closed.
    private func pruneRecentlyClosed(under workspace: Workspace) {
        let root = workspace.diskPath.standardizedFileURL.path
        recentlyClosed.removeAll { entry in
            entry.workspaceId == workspace.id
                || pathIsInside(entry.cwd.standardizedFileURL.path, root: root)
        }
    }

    func closeWorkspace(_ workspace: Workspace) {
        guard tabCloseCoordinator.prepare(workspace.root.allPanes.flatMap(\.tabs)) else { return }
        for pane in workspace.root.allPanes {
            for tab in pane.tabs {
                teardownSessionMonitors(tab)
            }
        }
        guard let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces.remove(at: idx)
        if workspaces.isEmpty {
            activeWorkspaceId = nil
        } else if activeWorkspaceId == workspace.id {
            let nextIdx = min(idx, workspaces.count - 1)
            activeWorkspaceId = workspaces[nextIdx].id
        }
        scheduleSave()
        if workspaces.isEmpty { onBecameEmpty?() }
    }

    func activateWorkspace(_ workspace: Workspace) {
        guard activeWorkspaceId != workspace.id else { return }
        invalidateTabConfirmations()
        fileTreeRootOverride = nil
        activeWorkspaceId = workspace.id
        workspace.activeSession?.lastActivated = Date()
        scheduleSave()
    }

    @discardableResult
    func duplicateWorkspace(_ workspace: Workspace) -> Workspace {
        addWorkspace(workingDirectory: workspace.workingDirectory)
    }

    /// Set or clear a user-provided workspace title. Empty / whitespace input
    /// clears the override so the sidebar label resumes tracking the cwd.
    func renameWorkspace(_ workspace: Workspace, to newTitle: String) {
        let next = normalizedTitle(newTitle)
        guard workspace.customTitle != next else { return }
        workspace.customTitle = next
        scheduleSave()
    }

    /// Set or clear a workspace's tag. `nil` clears it; picking the colour a
    /// workspace already carries is treated as a clear by the caller, so the
    /// same swatch toggles.
    func setTag(_ tag: WorkspaceTag?, for workspace: Workspace) {
        guard workspace.tag != tag else { return }
        workspace.tag = tag
        scheduleSave()
    }

    /// Reorder workspaces in the sidebar — dragged workspace takes the
    /// destination index, others shift.
    func moveWorkspace(from sourceIndex: Int, to destIndex: Int) {
        guard sourceIndex != destIndex,
              (0..<workspaces.count).contains(sourceIndex),
              (0..<workspaces.count).contains(destIndex) else { return }
        let source = workspaces[sourceIndex]
        let rootId = source.worktreeParentId ?? source.id
        let movingIndices = workspaces.indices.filter { idx in
            let ws = workspaces[idx]
            return ws.id == rootId || ws.worktreeParentId == rootId
        }
        guard !movingIndices.contains(destIndex) else { return }

        let movingIds = Set(movingIndices.map { workspaces[$0].id })
        let moving = workspaces.filter { movingIds.contains($0.id) }
        var remaining = workspaces.filter { !movingIds.contains($0.id) }
        let destination = workspaces[destIndex]
        let destinationRoot = destination.worktreeParentId ?? destination.id
        let destinationFamily = remaining.indices.filter {
            remaining[$0].id == destinationRoot || remaining[$0].worktreeParentId == destinationRoot
        }
        // Insert at a family boundary, never between another parent and child.
        let insertAt = sourceIndex < destIndex ? (destinationFamily.last.map { $0 + 1 } ?? remaining.count)
            : (destinationFamily.first ?? 0)
        remaining.insert(contentsOf: moving, at: insertAt)
        workspaces = remaining
        scheduleSave()
    }

    /// Payload for the "Close Other Workspaces" confirm sheet — captured
    /// when at least one of the workspaces about to close is a worktree,
    /// so the sheet can show the count and make the directory deletion
    /// explicit before running it.
    struct BulkRemovalRequest {
        let keeping: Workspace
        let others: [Workspace]
        let worktreeOthers: [Workspace]

        @MainActor
        init(keeping: Workspace, others: [Workspace]) {
            self.keeping = keeping
            self.others = others
            self.worktreeOthers = others.filter { $0.worktreeParentId != nil }
        }
    }

    func closeOtherWorkspaces(keeping workspace: Workspace) {
        // Keep the workspace's worktree family intact so we never strand
        // a worktree without its source (and vice versa):
        //  - keeping a source: also keep every worktree under it
        //  - keeping a worktree: also keep its source (siblings still close)
        var keepIds: Set<UUID> = [workspace.id]
        if let parentId = workspace.worktreeParentId {
            keepIds.insert(parentId)
        } else {
            for ws in workspaces where ws.worktreeParentId == workspace.id {
                keepIds.insert(ws.id)
            }
        }
        let others = workspaces.filter { !keepIds.contains($0.id) }
        if others.contains(where: { $0.worktreeParentId != nil }) {
            ProcessTabs.shared.close(others, from: self)
            return
        }
        for ws in others { closeWorkspace(ws) }
    }

    /// Executes the fixed bulk-close targets through the batch service.
    /// `alsoDelete = true` runs `git worktree remove --force` + branch-d
    /// on each worktree in the others list before closing; `alsoDelete
    /// = false` just drops them from the sidebar with disk untouched
    /// (v0.19.0 default — destructive removal is the checkbox path).
    /// Failed rows remain open; successful rows close.
    func performCloseOthers(_ request: BulkRemovalRequest, alsoDelete: Bool) async -> String? {
        let batch = CloseWorkspaceBatch(targets: request.others, store: self)
        batch.alsoDelete = alsoDelete
        return await batch.execute()
    }

    // MARK: - Tabs

    enum TabConnection {
        case inheritWorkspace
        case local
        case ssh(String)
    }

    /// `rawLaunchCommand` (the CLI's `open -e`) rides AGENTPAD_AGENT verbatim —
    /// see `makeSessionConfig(rawLaunchCommand:)`. Only meaningful with the
    /// plain `.terminal` template; the CLI controller is its one caller.
    /// `activate` and `spawnInBackground` travel as an inverse PAIR from the
    /// CLI's --no-focus; passing `activate: false` alone gets a tab on the
    /// lazy spawn-on-reveal path (restore semantics), which for a `-e`
    /// command is exactly the dead-tab shape issue #59 was about.
    @discardableResult
    func addTab(
        in workspace: Workspace,
        pane: Pane? = nil,
        template: AgentTemplate = .terminal,
        initialCwd: URL? = nil,
        conversationId: String? = nil,
        forceResume: Bool = false,
        claudeResolution: Result<String, ClaudeSessionResume.Refusal>? = nil,
        initialPrompt: String? = nil,
        rawLaunchCommand: String? = nil,
        customTitle: String? = nil,
        activate: Bool = true,
        spawnInBackground: Bool = false,
        connection: TabConnection = .inheritWorkspace,
        profile: AgentProfile? = nil,
        launchOrigin: AgentLaunchOrigin? = nil
    ) -> Session {
        // The raw channel replaces the template's own launch command inside
        // makeSessionConfig, but everything else (Session.agent identity,
        // conversation-id capture, resume persistence) would still run with
        // the template's semantics — a silent mismatch. Keep the invariant
        // executable, not a comment.
        precondition(template.isShell || rawLaunchCommand == nil,
                     "rawLaunchCommand is only valid with a shell template")
        guard let target = pane ?? workspace.activePane ?? workspace.root.firstPane else {
            preconditionFailure("workspace has no panes")
        }
        // Precedence: explicit caller cwd (`reopenLastClosedTab`,
        // right-click "Ask <agent>") > template's pinned cwd
        // (`TerminalPreset.path` via `AgentTemplate.extraCwd`) > workspace
        // cwd. `~/` is expanded; a vanished path falls back to `$HOME` via
        // `resolvedSpawnCwd`.
        let cwd = initialCwd
            ?? template.extraCwd.map { resolvedSpawnCwd(($0 as NSString).expandingTildeInPath) }
            ?? workspace.workingDirectory
        let sshHost: String? = switch connection {
        case .inheritWorkspace: workspace.sshRemoteHost
        case .local: nil
        case .ssh(let host): host
        }
        let session = spawnSession(template: template, initialCwd: cwd, conversationId: conversationId, forceResume: forceResume, claudeResolution: claudeResolution, initialPrompt: initialPrompt, sshRemoteHost: sshHost, rawLaunchCommand: rawLaunchCommand, customTitle: customTitle, spawnInBackground: spawnInBackground, profile: profile, launchOrigin: launchOrigin)
        configureSession(session, in: workspace, codexRolloutId: session.resumedConversationId)
        target.tabs.append(session)
        // `activate: false` (CLI --no-focus) appends WITHOUT touching the
        // active-tab/pane identity — the browser's background-tab shape. The
        // file-tree override invalidation is identity-coupled, so it stays
        // inside the gate too (nothing active changed).
        if activate {
            invalidateTabConfirmations()
            target.activeTabId = session.id
            if workspace.activePaneId != target.id {
                workspace.activePaneId = target.id
            }
            invalidateStaleFileTreeRootOverride()
        }
        scheduleAgentProfileAdoption()
        scheduleSave()
        return session
    }

    @discardableResult
    func duplicateTab(_ session: Session, in workspace: Workspace) -> Session? {
        if let route = session.toolRoute { return openToolTab(route) }
        guard let pane = pane(containing: session, in: workspace) else { return nil }
        // AgentPad: duplicating a channel tab opens the same channel.
        if let channel = session.channel { return openChannelTab(channel, in: workspace, pane: pane) }
        if let inbox = session.inbox { return openInboxTab(inbox, in: workspace, pane: pane) }
        return addTab(in: workspace, pane: pane, template: session.agent, initialCwd: session.currentDirectory,
            connection: session.sshWorkspaceHost.map(TabConnection.ssh) ?? .local,
            profile: session.profileID.flatMap(agentProfiles.profile), launchOrigin: session.launchOrigin)
    }

    /// History-row convenience — the seam's true dependency is only the
    /// (agent, conversation, cwd) triple below, so a scanner record just
    /// forwards its three fields.
    ///
    /// Returns the Result rather than an optional on purpose: a refusal here
    /// is a CONFIGURATION problem the user has to go fix (launch options
    /// disabling persistence, an id this agent can't take), so the reason
    /// has to survive far enough to be shown. Collapsing it to nil made a
    /// history click do nothing at all, with no way to find out why.
    @discardableResult
    func resumeAgentSession(_ record: AgentSessionRecord, claudeResolution: Result<String, ClaudeSessionResume.Refusal>? = nil) -> Result<Session, ResumeRefusal> {
        resumeAgentSession(
            agentId: record.agentId, conversationId: record.conversationId, cwd: record.cwd, claudeResolution: claudeResolution
        )
    }

    /// Resume a conversation: a new tab in the active workspace, running the
    /// agent with its resume arguments, spawned in the conversation's own
    /// directory (a different cwd would break every file reference the
    /// conversation holds). A missing directory refuses the launch.
    /// `forceResume` because both callers (History row click, deep link) are
    /// explicit asks — the `agents.resumeConversations` setting only governs
    /// automatic relaunch-time resume.
    @discardableResult
    func resumeAgentSession(agentId: String, conversationId: String, cwd: URL,
                            claudeResolution: Result<String, ClaudeSessionResume.Refusal>? = nil) -> Result<Session, ResumeRefusal> {
        if let binding = agentProfiles.binding(agentID: agentId, conversationID: conversationId) {
            return resumeProfileConversation(binding, claudeResolution: claudeResolution)
        }
        guard isDirectory(cwd) else { return .failure(.missingFolder(cwd.path)) }
        let visibility = conversationVisibility()
        // All sessions resolves off-main. Synchronous callers also resolve only
        // once, then carry that same result through validation and command building.
        let resolution = agentId == AgentTemplate.claudeCodeID
            ? claudeResolution ?? ClaudeSessionResume.resolve(conversationId, root: claudeProjectsRoot, visibility: visibility)
            : nil
        if let refusal = Self.resumeRefusal(
            agentId: agentId, conversationId: conversationId, options: optionsProvider,
            visibility: visibility, claudeProjectsRoot: claudeProjectsRoot, claudeResolution: resolution
        ) {
            return .failure(refusal)
        }
        guard let template = AgentTemplate.builtin(id: agentId) else {
            return .failure(.agentCannotResume)
        }
        let spawned = localSpawn(
            template: template,
            cwd: cwd,
            cwdIsConfirmed: true,
            conversationId: conversationId,
            forceResume: true,
            claudeResolution: resolution
        )
        activateWorkspace(spawned.workspace)
        return .success(spawned.session)
    }

    /// Why a resume was refused, decided before any session exists.
    /// Whether a resume would be refused without creating a workspace/tab;
    /// Claude checks the run journal and an exact local transcript. The deep-link and
    /// CLI paths ask first, because reaching `resumeAgentSession` may already
    /// have built a window to land in, and a window created for a request
    /// that then fails is one the user has to close (and one the persistence
    /// layer would otherwise restore at next launch).
    ///
    /// Everything that would make `spawnSession` silently drop the resume id
    /// lives here, so a refusal never leaves a tab that quietly started a
    /// FRESH conversation. It mirrors `spawnSession`'s conditions for THIS
    /// path specifically: `forceResume` is true, no initial prompt is passed,
    /// and `localSpawn` guarantees a local (non-SSH) workspace — so these are
    /// the only ways the id can still vanish.
    @MainActor
    static func resumeRefusal(
        agentId: String,
        conversationId: String,
        options: @MainActor (String) -> String? = { AgentPadSettingsModel.shared.agentOptions[$0] },
        visibility: ChannelConversationFilter = .current(),
        claudeProjectsRoot: URL = ClaudeSessionResume.projectsRoot(),
        claudeResolution: Result<String, ClaudeSessionResume.Refusal>? = nil
    ) -> ResumeRefusal? {
        guard visibility.allows(agentId: agentId, conversationId: conversationId, root: claudeProjectsRoot) else { return .channelConversation }
        guard let template = AgentTemplate.builtin(id: agentId), template.supportsResume else {
            return .agentCannotResume
        }
        guard template.persistsConversation(extraOptions: options(template.id)) else {
            return .launchOptionsDisablePersistence
        }
        guard template.normalizedConversationId(conversationId) != nil else {
            return .unusableConversationId
        }
        if agentId == AgentTemplate.claudeCodeID,
           case .failure(let refusal) = claudeResolution ?? ClaudeSessionResume.resolve(conversationId, root: claudeProjectsRoot, visibility: visibility) {
            return .claudeResume(refusal)
        }
        return nil
    }

    enum ResumeRefusal: Error, Equatable {
        case agentCannotResume
        case missingFolder(String)
        case launchOriginUnavailable
        case profileUnavailable
        case templateUnavailable
        case launchOptionsDisablePersistence
        case unusableConversationId
        case channelConversation
        case claudeResume(ClaudeSessionResume.Refusal)

        func message(agentId: String, conversationId: String) -> String {
            switch self {
            case .missingFolder(let path):
                return "Original folder not found: \(path). This session cannot resume in another folder."
            case .launchOriginUnavailable:
                return "The original launch configuration is unavailable or has changed. Open the existing tab from Sessions, or start a new session."
            case .profileUnavailable:
                return "This agent is no longer available."
            case .templateUnavailable:
                return "This agent type is no longer available. Check Settings → Agents."
            case .agentCannotResume:
                return "agent '\(agentId)' does not support resuming sessions"
            case .launchOptionsDisablePersistence:
                return "the launch options for '\(agentId)' disable session persistence, so the conversation could not be resumed"
            case .unusableConversationId:
                return "'\(conversationId)' is not a conversation id \(agentId) can resume"
            case .channelConversation:
                return "This conversation is only available through its channel."
            case .claudeResume(let refusal):
                return refusal.message
            }
        }
    }

    /// The workspace a LOCAL spawn may land in. An SSH workspace would wrap
    /// the launch in agentpad-ssh (`makeSessionConfig(sshHost:)`) — for resume
    /// that also drops the local-only resume id — so: the active workspace
    /// if it's local, else the first local one, else a fresh workspace at
    /// `fallbackCwd` so the request can never silently no-op. One policy for
    /// both explicit-spawn front doors (History/deep-link resume, CLI open);
    /// a future exclusion (worktree children, new workspace kinds) lands in
    /// both by construction.
    /// `cwdIsConfirmed` says the caller has ALREADY established that `cwd`
    /// is a directory — off the main actor, ideally. It matters twice over:
    /// the probe it skips is a main-actor `stat` that a dead network volume
    /// freezes the whole UI on, and its `$HOME` fallback SILENTLY relocates
    /// the launch. For `agentpad-cli open -e` that means running the caller's
    /// command somewhere it never asked for — in the home directory rather
    /// than the project — and still answering "ok". A caller that has
    /// verified the path wants a failure there, not a different directory.
    ///
    /// Resume verifies its original cwd first and always sets this true.
    /// A nil `cwd` means "wherever the landing workspace already is" — the
    /// caller named no directory, so `addTab`/`addWorkspace` fall back to the
    /// workspace's own working directory rather than to some guess made here.
    /// That is what `agentpad-cli open` without `--cwd` asks for.
    func localSpawn(
        template: AgentTemplate,
        cwd: URL?,
        cwdIsConfirmed: Bool = false,
        conversationId: String? = nil,
        forceResume: Bool = false,
        claudeResolution: Result<String, ClaudeSessionResume.Refusal>? = nil,
        rawLaunchCommand: String? = nil,
        customTitle: String? = nil,
        activate: Bool = true,
        spawnInBackground: Bool = false
    ) -> (workspace: Workspace, session: Session) {
        let dir = cwd.map { cwdIsConfirmed ? $0 : resolvedSpawnCwd($0.path) }
        if let existing = (active?.sshRemoteHost == nil ? active : nil)
            ?? workspaces.first(where: { $0.sshRemoteHost == nil }) {
            let session = addTab(
                in: existing,
                template: template,
                initialCwd: dir,
                conversationId: conversationId,
                forceResume: forceResume,
                claudeResolution: claudeResolution,
                rawLaunchCommand: rawLaunchCommand,
                customTitle: customTitle,
                activate: activate,
                spawnInBackground: spawnInBackground
            )
            return (existing, session)
        }
        // Nothing local to land in. The fresh workspace's own seed tab IS
        // the launch — adding a tab beside it would leave a blank shell and
        // a second PTY behind every such call. A background spawn keeps the
        // new workspace out of the way too: it appears in the sidebar but
        // the one the user is looking at stays active. In that case the
        // seed tab is its pane's ACTIVE tab inside a hidden workspace
        // container, so what makes it run is the engine's
        // `spawnsWhileHidden` exemption alone — PaneView's offscreen mount
        // only serves non-active tabs in existing panes.
        let workspace = addWorkspace(
            workingDirectory: dir,
            template: template,
            conversationId: conversationId,
            forceResume: forceResume,
            claudeResolution: claudeResolution,
            rawLaunchCommand: rawLaunchCommand,
            customTitle: customTitle,
            activate: activate,
            spawnInBackground: spawnInBackground
        )
        // `addWorkspace` always seeds one tab; the fallback keeps the return
        // total rather than force-unwrapping an invariant held elsewhere.
        let session = workspace.activeSession ?? addTab(
            in: workspace,
            template: template,
            initialCwd: dir,
            conversationId: conversationId,
            forceResume: forceResume,
            claudeResolution: claudeResolution,
            rawLaunchCommand: rawLaunchCommand,
            customTitle: customTitle,
            activate: activate,
            spawnInBackground: spawnInBackground
        )
        return (workspace, session)
    }

    /// The open tab already running `conversationId`, if any — so a deep link
    /// jumps to the live tab instead of spawning a duplicate `--resume` of a
    /// conversation that's already attached. `conversationId` (the persisted
    /// id, overwritten by hook-reporting agents like Claude on every new
    /// conversation) is the authority when present; `resumedConversationId`
    /// (spawn-time, written once, never updated) only counts when no
    /// persisted id exists — else a Claude tab that `/clear`ed to a new
    /// conversation would still match its old resume id and swallow the
    /// resume. Known residue this can't see: a non-reporting agent's
    /// persisted id survives the agent exiting or the resume setting being
    /// off, so a match can reveal a tab that RAN the conversation but no
    /// longer does — the safe direction (the user lands on a related tab and
    /// can resume from History) versus duplicate-resuming a live one.
    func findOpenConversation(agentId: String, conversationId: String)
        -> (workspace: Workspace, session: Session)? {
        guard conversationVisibility().allows(agentId: agentId, conversationId: conversationId) else { return nil }
        if agentId == AgentTemplate.claudeCodeID,
           case .failure = ClaudeSessionResume.resolve(conversationId, root: claudeProjectsRoot, visibility: conversationVisibility()) {
            return nil
        }
        for workspace in workspaces {
            for pane in workspace.root.allPanes {
                for session in pane.tabs {
                    guard session.agent.rosterId == agentId else { continue }
                    let matches = session.conversationId != nil
                        ? session.conversationId == conversationId
                        : session.resumedConversationId == conversationId
                    if matches { return (workspace, session) }
                }
            }
        }
        return nil
    }

    /// Set or clear a user-provided tab title. Empty / whitespace input clears
    /// the override so the title resumes tracking the working directory.
    func renameTab(_ session: Session, to newTitle: String) {
        // AgentPad: a chat tab takes its destination’s name (DESIGN-F2).
        guard session.hasProcess else { return }
        let next = normalizedTitle(newTitle)
        guard session.customTitle != next else { return }
        session.customTitle = next
        scheduleSave()
    }

    func moveTab(from sourceIndex: Int, to destIndex: Int, in pane: Pane) {
        guard sourceIndex != destIndex,
              (0..<pane.tabs.count).contains(sourceIndex),
              (0..<pane.tabs.count).contains(destIndex) else { return }
        let tab = pane.tabs.remove(at: sourceIndex)
        tab.terminalConfirmation.invalidate()
        tab.tabState?.leave(moving: true)
        pane.tabs.insert(tab, at: destIndex)
        scheduleSave()
    }

    /// Move a live tab between panes, keeping the source layout even when
    /// emptied. Closing a tab still has its existing collapse semantics.
    func moveTab(_ session: Session, to destPane: Pane, at destIndex: Int, in workspace: Workspace) {
        guard workspace.root.pane(id: destPane.id) === destPane,
              let sourcePane = workspace.root.pane(containingSessionId: session.id) else { return }
        if sourcePane.id == destPane.id { return }
        guard let sourceIndex = sourcePane.tabs.firstIndex(where: { $0.id == session.id }) else { return }
        detachSession(session, from: sourcePane, at: sourceIndex, in: workspace, keepingEmptyPane: true)
        attachSession(session, to: destPane, at: destIndex, in: workspace)
    }

    /// Removes `session` from `pane`. An emptied pane collapses — cascading
    /// to closing the workspace, and the window, when it was the last one;
    /// otherwise the active-tab crown passes to the neighbour and the
    /// workspace cwd re-syncs. Structural only: the engine keeps running, so
    /// this serves both `closeTab` (which terminates first) and a tab move
    /// (which re-homes the live session elsewhere).
    private func detachSession(_ session: Session, from pane: Pane, at idx: Int, in workspace: Workspace, keepingEmptyPane: Bool = false) {
        session.terminalConfirmation.invalidate()
        session.tabState?.leave(moving: true)
        (session.engine as? ChannelTabEngine)?.conversation.confirmation.invalidate()
        pane.tabs.remove(at: idx)
        if pane.tabs.isEmpty {
            pane.activeTabId = nil
            if !keepingEmptyPane {
                closePane(pane, in: workspace)
                return
            }
        } else if pane.activeTabId == session.id {
            let next = pane.tabs[min(idx, pane.tabs.count - 1)]
            pane.activeTabId = next.id
            if next.hasProcess, workspace.activePane?.id == pane.id, workspace.workingDirectory != next.currentDirectory {
                workspace.workingDirectory = next.currentDirectory
            }
        }
        invalidateStaleFileTreeRootOverride()
        scheduleSave()
    }

    /// Inserts an existing `session` into `destPane` at `destIndex` and
    /// promotes it to the active tab + active pane.
    private func attachSession(_ session: Session, to destPane: Pane, at destIndex: Int, in workspace: Workspace) {
        invalidateTabConfirmations()
        let insertIndex = min(max(destIndex, 0), destPane.tabs.count)
        destPane.tabs.insert(session, at: insertIndex)
        // AgentPad: a channel tab's Close now goes to this store.
        holdChannelClose(session)
        destPane.activeTabId = session.id
        workspace.activePaneId = destPane.id
        session.lastActivated = Date()
        if let zoomed = workspace.zoomedPaneId, zoomed != destPane.id { workspace.zoomedPaneId = nil }
        // Promoting to active mirrors `activateTab` so the sidebar title and
        // the next tab's spawn cwd follow the new focus without waiting for
        // the next OSC 7.
        if session.hasProcess, workspace.workingDirectory != session.currentDirectory {
            workspace.workingDirectory = session.currentDirectory
        }
        invalidateStaleFileTreeRootOverride()
        scheduleAgentProfileAdoption()
        scheduleSave()
    }

    /// One-shot drop handler for tab reorder gestures. Dispatches three ways:
    /// a same-pane index reorder when source == dest, a cross-pane session
    /// move within this window, or — when the session isn't in this window at
    /// all — a cross-window adoption from whichever peer store owns it.
    /// `destIndex` is the target item's current index in `destPane.tabs` (or
    /// `destPane.tabs.count` for "drop at end").
    @discardableResult
    func handleTabDrop(droppedId: UUID, to destPane: Pane, at destIndex: Int, in workspace: Workspace) -> Bool {
        guard !isTerminated, workspaces.contains(where: { $0 === workspace }),
              workspace.root.pane(id: destPane.id) === destPane else { return false }
        if let sourcePane = workspace.root.pane(containingSessionId: droppedId),
           let session = sourcePane.tabs.first(where: { $0.id == droppedId }) {
            if sourcePane.id == destPane.id {
                guard let from = sourcePane.tabs.firstIndex(where: { $0.id == droppedId }) else { return false }
                let to = min(max(destIndex, 0), sourcePane.tabs.count - 1)
                guard from != to else { return false }
                moveTab(from: from, to: to, in: sourcePane)
            } else {
                moveTab(session, to: destPane, at: destIndex, in: workspace)
            }
            return true
        }
        // Same store: only the callbacks' workspace changes. Keep monitor
        // state, including a Codex launch's exclusion snapshot and retries;
        // conversationId may still belong to a previous run in this tab.
        if let (sourceWorkspace, sourcePane) = location(ofSessionId: droppedId),
           let index = sourcePane.tabs.firstIndex(where: { $0.id == droppedId }) {
            let session = sourcePane.tabs[index]
            draggingTabId = nil
            detachSession(session, from: sourcePane, at: index, in: sourceWorkspace, keepingEmptyPane: true)
            attachSession(session, to: destPane, at: destIndex, in: workspace)
            wireSessionCallbacks(engine: session.engine, session: session, workspace: workspace)
            return true
        }
        // The drag started in another window: take the session from the peer
        // store that owns it, slot it in here, and re-point its engine
        // callbacks at this store so focus / title / activity events follow.
        for source in peerStores() where source !== self {
            guard let original = source.location(ofSessionId: droppedId),
                  let index = original.pane.tabs.firstIndex(where: { $0.id == droppedId }) else { continue }
            let candidate = original.pane.tabs[index]
            if let route = candidate.toolRoute, let existing = allSessions.first(where: {
                $0.toolRoute?.key(windowID: windowID) == route.key(windowID: windowID)
            }), let target = location(ofSessionId: existing.id) {
                activateWorkspace(target.workspace); activateTab(existing, in: target.workspace)
                return false // Window singleton collision: keep the source edit intact.
            }
            guard source.tabCloseCoordinator.prepare([candidate], moving: true) else { return false }
            let sourceActive = original.pane.activeTabId
            let sourcePaneID = original.workspace.activePaneId
            let sourceCwd = original.workspace.workingDirectory
            let sourceZoom = original.workspace.zoomedPaneId
            let destinationActive = destPane.activeTabId
            let destinationPaneID = workspace.activePaneId
            let destinationCwd = workspace.workingDirectory
            let destinationZoom = workspace.zoomedPaneId
            guard let session = source.surrenderSession(id: droppedId) else { return false }
            attachSession(session, to: destPane, at: destIndex, in: workspace)
            configureSession(session, in: workspace, codexRolloutId: session.conversationId)
            if let left = source.persistence as? WindowPersistence,
               let right = persistence as? WindowPersistence, left.app === right.app {
                do {
                    try left.app.setWindows([
                        PersistedWindow(id: left.windowId, state: source.snapshot(), frame: left.frameProvider?()),
                        PersistedWindow(id: right.windowId, state: snapshot(), frame: right.frameProvider?())
                    ]).get()
                } catch {
                    // Surrender every destination monitor before returning the
                    // live tab, so destination termination cannot delete its records.
                    teardownSessionMonitors(session, keepForTransfer: true)
                    destPane.tabs.removeAll { $0 === session }
                    source.attachSession(session, to: original.pane, at: index, in: original.workspace)
                    source.configureSession(session, in: original.workspace, codexRolloutId: session.conversationId)
                    original.pane.activeTabId = sourceActive; original.workspace.activePaneId = sourcePaneID
                    original.workspace.workingDirectory = sourceCwd; original.workspace.zoomedPaneId = sourceZoom
                    destPane.activeTabId = destinationActive; workspace.activePaneId = destinationPaneID
                    workspace.workingDirectory = destinationCwd; workspace.zoomedPaneId = destinationZoom
                    session.tabState?.saveError = "The tab could not be moved. Its original location and edits were kept."
                    persistenceError = error.localizedDescription
                    return false
                }
            }
            return true
        }
        return false
    }

    func canDropTab(_ id: UUID, in workspace: Workspace) -> Bool {
        guard workspaces.contains(where: { $0 === workspace }),
              workspace.root.pane(containingSessionId: id) == nil else { return false }
        return findSession(id: id) != nil || peerStores().contains { $0 !== self && !$0.isTerminated && $0.findSession(id: id) != nil }
    }

    /// Sidebar drops append to the destination's focused pane and reveal it.
    @discardableResult
    func handleTabDrop(droppedId: UUID, in workspace: Workspace) -> Bool {
        guard canDropTab(droppedId, in: workspace), let pane = workspace.activePane,
              handleTabDrop(droppedId: droppedId, to: pane, at: pane.tabs.count, in: workspace) else { return false }
        activateWorkspace(workspace)
        return true
    }

    /// A workspace born from a tab has no throwaway shell or agent process.
    @discardableResult
    func moveTabToNewWorkspace(_ id: UUID) -> Workspace? {
        guard !isTerminated,
              let session = findSession(id: id) ?? peerStores().lazy
                .filter({ $0 !== self && !$0.isTerminated }).compactMap({ $0.findSession(id: id) }).first else { return nil }
        let workspace = Workspace(workingDirectory: session.currentDirectory, root: PaneNode(pane: Pane()))
        // Workspace titles are persisted without a channel access check.
        // Never copy the channel's currently visible name into that state.
        workspace.customTitle = session.hasProcess ? normalizedTitle(session.title) : (session.toolRoute?.title ?? "Channel")
        workspace.sshRemoteHost = session.sshWorkspaceHost
        workspaces.append(workspace)
        guard handleTabDrop(droppedId: id, in: workspace) else {
            workspaces.removeAll { $0 === workspace }
            return nil
        }
        return workspace
    }

    /// Removes the session with `id` from this store and returns it for a
    /// peer store (another window) to adopt — its engine, libghostty surface,
    /// scrollback, PTY and agent state all stay alive. Returns nil when this
    /// store doesn't own the id. `internal`, not `private`: `handleTabDrop`
    /// calls it on each peer store.
    func surrenderSession(id: UUID) -> Session? {
        guard !isTerminated, let (workspace, pane) = location(ofSessionId: id),
              let idx = pane.tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let session = pane.tabs[idx]
        // The drag started in this window, so `onDrag` set our `draggingTabId`
        // — and the destination store's `dropDestination` defer clears only
        // its own. Clear ours so this window's drop indicators reset.
        draggingTabId = nil
        teardownSessionMonitors(session, keepForTransfer: true)
        detachSession(session, from: pane, at: idx, in: workspace, keepingEmptyPane: true)
        return session
    }

    /// Routes the right-click "Move to New Window" request to `AppDelegate`,
    /// which creates a fresh window and moves the session into it.
    func moveTabToNewWindow(_ sessionId: UUID) {
        moveToNewWindow(sessionId)
    }

    func closeOtherTabs(keeping session: Session, in workspace: Workspace) {
        guard let pane = pane(containing: session, in: workspace) else { return }
        let toClose = pane.tabs.filter { $0.id != session.id }
        for tab in toClose { closeTab(tab, in: workspace) }
    }

    func closeTabsToRight(of session: Session, in workspace: Workspace) {
        guard let pane = pane(containing: session, in: workspace),
              let idx = pane.tabs.firstIndex(where: { $0.id == session.id }) else { return }
        // Snapshot direct refs — `closeTab` mutates `pane.tabs` mid-iteration.
        let toClose = Array(pane.tabs[(idx + 1)...])
        for tab in toClose { closeTab(tab, in: workspace) }
    }

    /// Completing the form must not close its host window when it is the last
    /// tab: the newly added agent needs to remain visible, without a seed PTY.
    func closeCompletedAgentForm(_ session: Session, in workspace: Workspace) {
        guard case .newAgent = session.toolRoute,
              let pane = pane(containing: session, in: workspace),
              let index = pane.tabs.firstIndex(where: { $0.id == session.id }) else { return }
        teardownSessionMonitors(session)
        detachSession(session, from: pane, at: index, in: workspace, keepingEmptyPane: true)
    }

    func closeTab(_ session: Session, in workspace: Workspace) {
        tabCloseCoordinator.request(session) { [weak self, weak session, weak workspace] in
            guard let self, let session, let workspace else { return }
            self.closeTab(session, in: workspace, recordHistory: true)
        }
        if session.tabState?.saveError != nil { activateWorkspace(workspace); activateTab(session, in: workspace) }
    }

    /// Like `closeTab` but skips the reopen-closed-tab history — for
    /// synthetic tabs the user never knowingly opened (e.g. the placeholder
    /// the new-window orchestration spawns before adopting a moved-in tab).
    /// Without this, `⌘⇧T` after a Move to New Window resurrects a phantom
    /// "terminal at ~" the user never closed.
    func discardTab(_ session: Session, in workspace: Workspace) {
        closeTab(session, in: workspace, recordHistory: false)
    }

    /// Drops the tab this store was born with, once the caller that caused
    /// the WINDOW to exist has landed the tab it actually wanted. A window
    /// built to serve one request (`agentpad-cli open`, a `agentpad://resume`
    /// arriving with zero terminal windows open) comes up with a seed tab of
    /// its own; leaving it behind means one request produced two tabs and
    /// two PTYs, and the caller — which is told about exactly one id — can
    /// neither find nor clean up the other. `discardTab` rather than
    /// `closeTab` keeps a synthetic placeholder out of the reopen stack.
    ///
    /// Deliberately gated on this store still having a newborn's exact shape
    /// (one workspace, and now exactly that seed plus the caller's tab):
    /// callers derive "I built this window" from the window layer, which has
    /// a narrow window where it can hand back a controller whose window is
    /// already closing. Being wrong by leaving a blank tab behind is
    /// recoverable; being wrong by closing a real session is not.
    func discardSeedTab(keeping session: Session) {
        guard workspaces.count == 1, let workspace = workspaces.first else { return }
        let tabs = workspace.root.allPanes.flatMap(\.tabs)
        guard tabs.count == 2, let seed = tabs.first(where: { $0.id != session.id }) else { return }
        discardTab(seed, in: workspace)
    }

    private func closeTab(_ session: Session, in workspace: Workspace, recordHistory: Bool) {
        guard let pane = pane(containing: session, in: workspace),
              let idx = pane.tabs.firstIndex(where: { $0.id == session.id }) else { return }
        // Closing the last tab of a worktree workspace cascades through
        // detachSession → closePane → closeWorkspace, which would bypass
        // the close review. Reroute here before any state mutates so
        // cancelling the review keeps the tab open.
        if workspace.closingLastTabCascadesIntoWorktreeRemoval {
            requestCloseWorkspace(workspace)
            return
        }
        if recordHistory {
            recordClosedTab(session, pane: pane, workspace: workspace)
        }
        teardownSessionMonitors(session)
        detachSession(session, from: pane, at: idx, in: workspace)
    }

    private func recordClosedTab(_ session: Session, pane: Pane, workspace: Workspace) {
        recentlyClosed.append(ClosedTabState(
            agent: session.agent,
            cwd: session.currentDirectory,
            customTitle: session.hasProcess ? session.customTitle : nil,
            workspaceId: workspace.id,
            paneId: pane.id,
            conversationId: session.conversationId,
            launchOrigin: session.launchOrigin,
            profileID: session.profileID,
            profileOriginalCwd: session.profileOriginalCwd,
            sshWorkspaceHost: session.sshWorkspaceHost,
            channel: session.channel,
            inbox: session.inbox,
            tool: session.toolRoute,
            navigation: session.tabState?.navigation,
            unavailableTab: session.unavailableTab,
            unavailableMessage: session.unavailableTab == nil ? nil : session.tabState?.message
        ))
        if recentlyClosed.count > Self.closedTabHistoryLimit {
            recentlyClosed.removeFirst(recentlyClosed.count - Self.closedTabHistoryLimit)
        }
    }

    /// Menu validation uses this instead of exposing the history itself.
    var canReopenClosedTab: Bool { !recentlyClosed.isEmpty }

    /// Pops the most recently closed tab off the history stack and re-spawns
    /// it. Routes back to the original workspace + pane when both still
    /// exist, falling back to the current workspace's active pane otherwise
    /// (a tab closed under a since-deleted workspace lands wherever the user
    /// is now). Returns the new session, or nil when the stack is empty.
    @discardableResult
    func reopenLastClosedTab() -> Session? {
        guard let state = recentlyClosed.popLast() else { return nil }
        if let tool = state.tool {
            let session = openToolTab(tool, navigation: state.navigation ?? TabNavigation())
            if var original = state.unavailableTab {
                original.id = session.id
                session.unavailableTab = original
                session.currentDirectory = URL(fileURLWithPath: original.currentDirectoryPath)
                session.tabState?.message = state.unavailableMessage
                scheduleSave()
            }
            return session
        }
        guard let workspace = workspaces.first(where: { $0.id == state.workspaceId }) ?? active else {
            return nil
        }
        let pane = workspace.root.allPanes.first { $0.id == state.paneId }
            ?? workspace.activePane
            ?? workspace.root.firstPane
        let binding = state.conversationId.flatMap {
            state.launchOrigin == nil && state.profileID == nil ? nil : agentProfiles.binding(agentID: state.agent.rosterId, conversationID: $0)
        }
        let profileID = binding?.profileID ?? state.profileID
        if let origin = state.launchOrigin, !profileTemplates().contains(where: { origin.matches($0) }) {
            let message = ResumeRefusal.launchOriginUnavailable.message(agentId: state.agent.rosterId, conversationId: state.conversationId ?? "")
            if let profileID { agentProfileErrors[profileID] = message }
            else { persistenceError = message }
            recentlyClosed.append(state)
            return nil
        }
        let profile = profileID.flatMap(agentProfiles.profile)
        let originalCwd = binding?.record.cwd ?? state.profileOriginalCwd ?? state.cwd
        if let id = profileID, profile == nil || !isDirectory(originalCwd) {
            let reason: ResumeRefusal = isDirectory(originalCwd) ? .profileUnavailable : .missingFolder(originalCwd.path)
            agentProfileErrors[id] = reason.message(agentId: state.agent.rosterId, conversationId: state.conversationId ?? "")
            revealAgentProfile(id)
            recentlyClosed.append(state)
            return nil
        }
        let cwd = profile == nil ? resolvedSpawnCwd(state.cwd.path) : originalCwd
        if let channel = state.channel, let pane {
            let session = openChannelTab(channel, in: workspace, pane: pane)
            activateWorkspace(workspace)
            activateTab(session, in: workspace)
            return session
        }
        // AgentPad: reopening a saved chat list must not start a shell.
        if let inbox = state.inbox, let pane {
            let session = openInboxTab(inbox, in: workspace, pane: pane)
            activateWorkspace(workspace)
            activateTab(session, in: workspace)
            return session
        }
        let session = addTab(
            in: workspace,
            pane: pane,
            template: state.agent,
            initialCwd: cwd,
            conversationId: state.conversationId,
            connection: state.sshWorkspaceHost.map(TabConnection.ssh) ?? .local,
            profile: profile, launchOrigin: state.launchOrigin
        )
        if let custom = state.customTitle, !custom.isEmpty {
            session.customTitle = custom
        }
        activateWorkspace(workspace)
        activateTab(session, in: workspace)
        return session
    }

    /// Cycle the active pane's tab selection. `direction` of `+1` advances
    /// to the next tab, `-1` to the previous; both wrap at the end. Per-pane,
    /// not workspace-wide — focus shouldn't jump panes when the user is
    /// asking to step through tabs in the pane they're looking at.
    func cycleTab(in workspace: Workspace, direction: Int) {
        guard let pane = workspace.activePane,
              let active = pane.activeTab,
              let currentIdx = pane.tabs.firstIndex(where: { $0 === active })
        else { return }
        activateTab(pane.tabs[pane.tabs.cyclicIndex(from: currentIdx, step: direction)], in: workspace)
    }

    func activateTab(_ session: Session, in workspace: Workspace) {
        // Switching to a tab counts as reading any notification that pointed at
        // it — clears the inbox entry + the bell dot without an explicit click.
        NotificationInbox.shared.markRead(forSession: session.id)
        // `spawnsInBackground` is deliberately NOT cleared here (or anywhere):
        // activation is a model write, the offscreen mount is a NEXT-FRAME
        // view effect — an activate-then-switch-away landing inside one
        // render commit would clear the only thing that keeps the hidden
        // mount coming back, stranding a never-spawned tab (Codex P2). The
        // flag is lifelong; PaneView's active-tab exclusion is the one
        // consumer gate, so the structure closes the race with no timing.
        guard let pane = pane(containing: session, in: workspace) else { return }
        session.lastActivated = Date()
        var changed = false
        if pane.activeTabId != session.id || workspace.activePaneId != pane.id { invalidateTabConfirmations() }
        if pane.activeTabId != session.id {
            pane.activeTabId = session.id
            changed = true
        }
        if workspace.activePaneId != pane.id {
            invalidateTabConfirmations()
            workspace.activePaneId = pane.id
            // Focusing a different pane while zoomed would route ⌘D /
            // ⌘T / cwd-sync at the now-hidden active pane. Auto-exit so
            // the visible pane = the active pane invariant holds.
            if let zoomed = workspace.zoomedPaneId, zoomed != pane.id {
                workspace.zoomedPaneId = nil
            }
            changed = true
        }
        if session.hasProcess, workspace.workingDirectory != session.currentDirectory {
            workspace.workingDirectory = session.currentDirectory
            changed = true
        }
        invalidateStaleFileTreeRootOverride()
        if changed { scheduleSave() }
    }

    // MARK: - Panes

    /// Toggle pane zoom for the active pane (keyboard / menu entry point
    /// — `⌘⇧E` operates on whatever pane has keyboard focus).
    func toggleZoom(in workspace: Workspace) {
        guard let active = workspace.activePaneId else { return }
        toggleZoom(in: workspace, paneId: active)
    }

    /// Toggle zoom for an explicit pane — used by the per-pane button and
    /// the right-click menu, so clicking the button on a non-active pane
    /// zooms *that* pane (and activates it so subsequent ⌘D / ⌘[ / ⌘]
    /// operate on the visibly-zoomed pane).
    func toggleZoom(in workspace: Workspace, paneId: UUID) {
        guard workspace.canZoom else { return }
        // Suspend per-frame `set_size` across the workspace for the zoom animation
        // (see suspendSizePropagationForLayoutAnimation).
        invalidateTabConfirmations()
        suspendSizePropagationForLayoutAnimation(workspace.root.allEngines)
        workspace.activePaneId = paneId
        workspace.zoomedPaneId = workspace.isZoomed(paneId) ? nil : paneId
        invalidateStaleFileTreeRootOverride()
        scheduleSave()
    }

    /// Suspend per-frame `ghostty_surface_set_size` across `engines` for the
    /// duration of a `withAnimation(Theme.chromeTransition)` layout change (pane
    /// zoom, sidebar / agent-panel show-hide), then end + flush once it settles.
    /// Without this, SwiftUI re-frames each surface every animation frame → a
    /// SIGWINCH burst (conda scrollback wipe) AND — since the vsync render loop is
    /// driven by those per-frame `setNeedsRender`s racing the display-link tick —
    /// visible flicker (issue #29). Refcounted begin/end (self-balanced, so
    /// overlapping animations compose; flush only when an engine's count hits 0);
    /// the local capture is robust (no shared/token state to strand). ~0.25s
    /// covers `Theme.chromeTransition`.
    private func suspendSizePropagationForLayoutAnimation(_ engines: [any TerminalEngine]) {
        guard !engines.isEmpty else { return }
        for engine in engines { engine.beginSizePropagationSuspension() }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            for engine in engines {
                engine.endSizePropagationSuspension()
                if !engine.suspendsSizePropagation { engine.flushSize() }
            }
        }
    }

    /// Splits `pane` in two. The existing pane stays as the first child of the
    /// new split; the second child is empty until a tab is opened or moved
    /// into it. Splitting never starts a terminal or agent. Returns the new
    /// pane (now focused) or nil if `pane` isn't found.
    @discardableResult
    func splitPane(_ pane: Pane, orientation: SplitOrientation, in workspace: Workspace) -> Pane? {
        guard let leafNode = workspace.root.paneNode(paneId: pane.id) else { return nil }
        guard case .pane(let existing) = leafNode.content else { return nil }
        invalidateTabConfirmations()
        let newPane = Pane()
        let firstChild = PaneNode(pane: existing)
        let secondChild = PaneNode(pane: newPane)
        leafNode.content = .split(orientation: orientation, first: firstChild, second: secondChild, fraction: 0.5)
        if orientation == .horizontal {
            AgentPadWindowLayout.rebalanceHorizontalSplits(
                in: workspace.root,
                alongPathTo: leafNode
            )
        }
        workspace.activePaneId = newPane.id
        // Splitting while zoomed = "I want to see what I'm creating". Drop
        // zoom so the new pane is visible. Guarded so a no-op write
        // doesn't trigger an extra Observable invalidation.
        if workspace.zoomedPaneId != nil { workspace.zoomedPaneId = nil }
        invalidateStaleFileTreeRootOverride()
        scheduleSave()
        return newPane
    }

    /// Removes `pane` and its tabs. If it's the workspace's only pane, the
    /// whole workspace closes. Otherwise the sibling pane collapses up to
    /// take the parent split's place.
    func closePane(_ pane: Pane, in workspace: Workspace) {
        guard tabCloseCoordinator.prepare(pane.tabs) else { return }
        guard let leafNode = workspace.root.paneNode(paneId: pane.id) else { return }
        // Worktree last-pane cascade — route through the confirm sheet
        // before any engines get terminated, so a sheet cancel leaves
        // the user's work intact.
        if leafNode === workspace.root && workspace.worktreeParentId != nil {
            requestCloseWorkspace(workspace)
            return
        }
        if workspace.zoomedPaneId == pane.id { workspace.zoomedPaneId = nil }
        // Tear down per-session watchers before terminating engines — same
        // contract as closeTab / closeWorkspace. The non-root collapse path
        // below returns without routing through those, so without this the
        // closed pane's git + Codex/Kiro watchers (DispatchSource fds) leak.
        // Idempotent: the root path re-stops via closeWorkspace (no-op).
        for tab in pane.tabs {
            teardownSessionMonitors(tab)
        }
        // Object identity, not id equality. After `splitPane`, the workspace
        // root keeps its original id but its content becomes a `.split`, while
        // a freshly-constructed child `PaneNode(pane: existing)` reuses the
        // same `pane.id`. Comparing ids would falsely match a leaf child whose
        // pane shares an id with the root and route through `closeWorkspace`.
        if leafNode === workspace.root {
            closeWorkspace(workspace)
            return
        }
        guard let info = workspace.root.parentInfo(forPane: pane.id) else { return }
        info.parent.content = info.sibling.content
        // After collapse, focus whichever pane is now nearest.
        if workspace.activePaneId == pane.id {
            workspace.activePaneId = info.sibling.firstPane?.id
            if let session = workspace.activeSession, session.hasProcess,
               workspace.workingDirectory != session.currentDirectory {
                workspace.workingDirectory = session.currentDirectory
            }
        }
        invalidateStaleFileTreeRootOverride()
        scheduleSave()
    }

    func focusPane(_ pane: Pane, in workspace: Workspace) {
        guard workspace.root.pane(id: pane.id) != nil else { return }
        pane.activeTab?.lastActivated = Date()
        var changed = false
        if workspace.activePaneId != pane.id {
            invalidateTabConfirmations()
            workspace.activePaneId = pane.id
            // Same "visible-pane = active-pane" invariant as activateTab —
            // cycling focus via ⌘[ / ⌘] off the zoomed pane drops zoom.
            if let zoomed = workspace.zoomedPaneId, zoomed != pane.id {
                workspace.zoomedPaneId = nil
            }
            changed = true
        }
        if let session = pane.activeTab, session.hasProcess, workspace.workingDirectory != session.currentDirectory {
            workspace.workingDirectory = session.currentDirectory
            changed = true
        }
        invalidateStaleFileTreeRootOverride()
        if changed { scheduleSave() }
    }

    /// Routes a hook event to the named session. On `.ended`, drops the leaf
    /// back to `.terminal` only if the agent reporting end matches the
    /// session's current agent — otherwise a Codex run inside a Claude tab
    /// (or a delayed `ended`) would wipe the still-active icon. Dropped once
    /// `terminate()` has run (`hookSession`).
    func applyHookEvent(agent: AgentTemplate, event: HookEvent, sessionId: UUID, details: HookLifecycleDetails = HookLifecycleDetails()) {
        guard let session = hookSession(id: sessionId) else { return }
        // An idle reminder must not replace the Stop's completion or discard
        // its background counts. A permission prompt is a new input request.
        if details.notificationType == "idle_prompt", session.backgroundWork != nil { return }
        let agentBefore = session.agent.id
        if event == .ended {
            // A custom agent based on this builtin shares its binary's
            // wrapper shim — the `ended` ping arrives with the builtin's
            // slug, not the custom's id. Match on the template's
            // baseAgentId snapshot (frozen at spawn time, see
            // `AgentTemplate.baseAgentId`) so a mid-run Settings edit
            // can't leave the tab pill stuck.
            if session.agent.id == agent.id || session.agent.baseAgentId == agent.id {
                // Auto-launch reports its own exit code. Interactive Bash
                // has no command-finished marker, so ended is its completion.
                handleAgentEnded(session, awaitExitOutcome: session.pendingAgentLaunch != nil
                                 || AgentPadShellIntegration.detectedUserShell != .bash)
                session.agent = .terminal
                session.launchOrigin = nil
            }
        } else if session.agent.isShell {
            // AgentPad: a new agent must report its own journal and process.
            session.answerBinding = nil
            session.personalBinding = nil
            session.resumedConversationId = nil
            // Includes the default Terminal *and* any TerminalPreset — a
            // user starting Claude inside a preset terminal should get
            // the same icon-upgrade the default Terminal does.
            session.agent = agent
            if session.launchOrigin?.matches(agent) != true {
                session.launchOrigin = nil
            }
            if let id = session.profileID, session.launchOrigin == nil || agentProfiles.profile(id)?.rosterID != agent.rosterId {
                session.profileID = nil
                session.profileOriginalCwd = nil
            }
            if !agent.isShell, session.effectiveRemoteHost == nil {
                // A manually launched agent starts here, not in the shell's
                // original folder. Do not reuse a previous run's conversation ID.
                session.profileAdoption = AgentProfileAdoption.Candidate(tabID: session.id, rosterID: agent.rosterId,
                    templateID: agent.id, launchOptions: session.launchOrigin?.options ?? optionsProvider(agent.id) ?? "",
                    folder: session.currentDirectory, conversationID: nil,
                    title: session.title, createdAt: Date())
                scheduleAgentProfileAdoption()
            }
        }
        // SessionStart → UserPromptSubmit on Claude (and BeforeAgent on Gemini)
        // re-fires `.running` per turn; the @Observable setter notifies every
        // sidebar/tab observer even on same-value assignment, so guard.
        // AgentPad: any lifecycle event but "attention" from the tab's own
        // agent is a turn boundary; calls still listed as open there will
        // report no end. Another agent run in the same tab says nothing
        // about Claude's calls.
        if event != .attention, session.agent.id == agent.id || session.agent.baseAgentId == agent.id || agentBefore == agent.id {
            session.openMainThreadCalls.removeAll()
        }
        // AgentPad: every lifecycle event restates the background work —
        // present only on a Stop that left some running.
        session.backgroundWork = details.hasBackgroundWork
            ? Session.BackgroundWork(subagents: details.backgroundSubagents, shells: details.backgroundShells)
            : nil
        session.hookStateAt = Date()
        applyNotificationTransition(session, state: event.activityState,
                                    reason: details.reason ?? (event == .turnComplete ? .completion : event == .turnFailure ? .failure : .input),
                                    continuesEpisode: details.notificationType == "idle_prompt")
        if session.agent.id != agentBefore { scheduleSave() }
        // A non-`ended` event means the agent just (re)started — for Codex,
        // (re)point the usage watcher so a manually-typed `codex` lights up
        // and a relaunch follows the freshly-created rollout file.
        if event != .ended {
            startCodexUsageIfNeeded(for: session)
            startKiroConversationIfNeeded(for: session)
        }
    }

    func applyShellEnvironment(_ env: [String: String], sessionId: UUID) {
        guard let session = hookSession(id: sessionId) else { return }
        session.shellEnvironment = env
        refreshEnvironment(for: session)
    }

    /// AgentPad: only a hook can establish export provenance; monitors call
    /// applyConversationId directly and only update the resumable history ID.
    func applyHookConversationId(conversationId: String, sessionId: UUID, provenance: AgentAnswerProvenance? = nil,
                                 failure: AgentAnswerTranscript.Problem? = nil, hook: AgentAnswerProvenance.Hook? = nil,
                                 inspector: AgentAnswerProvenance.Inspector = .init()) {
        guard let session = hookSession(id: sessionId) else { return }
        AgentAnswerSource.recordHook(conversation: conversationId, session: session, provenance: provenance, failure: failure, hook: hook, inspector: inspector)
        applyConversationId(conversationId: conversationId, sessionId: sessionId)
    }

    /// Stores the conversation id reported by an agent's hook or monitor onto
    /// the originating Session and schedules a save so the value survives
    /// across AgentPad launches. Same-value writes are dropped so we don't
    /// churn persistence on every hook firing — Claude pings `session_id`
    /// on every SessionStart / UserPromptSubmit / Stop / SessionEnd, so the
    /// dedup keeps the debounce loop quiet.
    func applyConversationId(conversationId: String, sessionId: UUID) {
        guard let session = hookSession(id: sessionId) else { return }
        if session.conversationId != conversationId {
            session.conversationId = conversationId
            scheduleSave()
        }
        bindProfileConversation(session)
    }

    /// Routes a Claude tool-call event (PreToolUse / PostToolUse) to the
    /// originating Session's rolling `toolCallEvents` buffer. Runtime-only
    /// — no `scheduleSave()` because `toolCallEvents` isn't persisted.
    /// Unknown sessionIds (race: tab closed mid-flight) drop silently;
    /// other UI keeps rendering.
    func applyToolCallEvent(
        agent: AgentTemplate,
        toolName: String,
        identifier: String,
        event: HookToolEvent,
        success: Bool?,
        toolUseId: String?,
        sessionId: UUID,
        mainThread: Bool = false
    ) {
        guard let session = hookSession(id: sessionId) else { return }

        switch event {
        case .pre:
            session.recordToolCallStart(
                toolName: toolName,
                identifier: identifier,
                toolUseId: toolUseId
            )
        case .post:
            // Missing success flag (parse miss / wire malformed) defaults
            // to true — better to show the call as succeeded than to
            // falsely flag failure on a Claude that ran fine.
            session.recordToolCallEnd(
                toolName: toolName,
                identifier: identifier,
                success: success ?? true,
                toolUseId: toolUseId
            )
        }
        guard mainThread else { return }
        if event == .pre {
            // A call without an id cannot be matched to its end, so it stays
            // open until its batch resolves.
            let key = toolUseId.flatMap { $0.isEmpty ? nil : $0 } ?? "unmatched:\(UUID().uuidString)"
            session.openMainThreadCalls.insert(key)
            // The call that just started is not the one being waited on.
            resumeIfNothingOpen(session, except: key)
        } else {
            if let toolUseId, !toolUseId.isEmpty { session.openMainThreadCalls.remove(toolUseId) }
            resumeIfNothingOpen(session, except: nil)
        }
    }

    /// AgentPad: hooks miss some transitions — a background task that ends
    /// without waking the agent, a permission granted to a background
    /// subagent, a prompt answered while another call still runs. Claude
    /// Code's own session status (`~/.claude/sessions/<pid>.json`) has them,
    /// so it corrects an own Claude tab once it is newer than the last hook
    /// event and has held for `claudeStatusSettle`.
    func reconcileWithClaudeStatus(_ claudeSessions: [ExternalAgentSession], now: Date = Date()) {
        // Two processes holding one conversation cannot be told apart here;
        // leave such a conversation to its hooks.
        let counts = Dictionary(claudeSessions.map { ($0.sessionId, 1) }, uniquingKeysWith: +)
        let byConversation = Dictionary(
            claudeSessions.filter { counts[$0.sessionId] == 1 }.map { ($0.sessionId, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        guard !isTerminated else { return }
        for workspace in workspaces {
            for session in workspace.root.allPanes.flatMap(\.tabs) {
                guard session.agent.id == AgentTemplate.claudeCodeID || session.agent.baseAgentId == AgentTemplate.claudeCodeID,
                      let conversation = session.conversationId,
                      let claude = byConversation[conversation],
                      let since = claude.statusSince,
                      now.timeIntervalSince(since) >= Self.claudeStatusSettle,
                      // Newer than the last hook event — or contradicting it
                      // for so long that a late hook, not Claude, is stale.
                      since > session.hookStateAt
                        || now.timeIntervalSince(session.hookStateAt) >= Self.claudeStatusOverride
                else { continue }
                switch claude.status {
                case .idle where session.activityState == .running || session.backgroundWork != nil:
                    // Background work can finish after Stop without waking
                    // Claude. Clear its counts without making another episode.
                    session.backgroundWork = nil
                    if session.activityState == .running {
                        applyNotificationTransition(session, state: .attention, reason: .completion)
                    }
                case .busy where session.activityState == .attention,
                     .shell where session.activityState == .attention && session.attentionReason == .input:
                    // Foreground work resumed, or a shell permission was
                    // answered. Shells alone cannot undo a completed turn.
                    session.openMainThreadCalls.removeAll()
                    applyNotificationTransition(session, state: .running)
                default:
                    break
                }
            }
        }
    }

    static let claudeStatusSettle: TimeInterval = 2
    static let claudeStatusOverride: TimeInterval = 15

    /// AgentPad: the main thread's batch resolved, so no prompt inside it is
    /// still open — whether the user approved or denied it.
    func applyToolBatchResolved(sessionId: UUID) {
        guard let session = hookSession(id: sessionId) else { return }
        session.openMainThreadCalls.removeAll()
        resumeIfNothingOpen(session, except: nil)
    }

    /// AgentPad: Claude reports "attention" when it stops mid-turn for a
    /// permission prompt or a question, and nothing reports the answer. A
    /// main-thread tool event shows the agent went on — but only once no other
    /// main-thread call of the batch is still open: with calls running in
    /// parallel, one of them may be the one waiting, and another finishing
    /// says nothing about it.
    private func resumeIfNothingOpen(_ session: Session, except key: String?) {
        guard session.activityState == .attention else { return }
        // A late PostToolUse/PostToolBatch belongs to the finished turn.
        // Only a new call (PreToolUse) can resume a completion or failure;
        // tool ends still resolve mid-turn permission/input waits.
        guard session.attentionReason == .input || key != nil else { return }
        var open = session.openMainThreadCalls
        if let key { open.remove(key) }
        guard open.isEmpty else { return }
        applyNotificationTransition(session, state: .running)
    }

    private func handleAgentEnded(_ session: Session, awaitExitOutcome: Bool) {
        onSessionWaitingEnded(session.id)
        session.awaitingAgentExitOutcome = awaitExitOutcome
        if !awaitExitOutcome {
            session.notificationPhase = "exit"
            session.notificationEpisode += 1
            onSessionAlert(session.id, .completed)
        }
    }

    /// Hook, status scan and tool progress use the same episode boundary.
    private func applyNotificationTransition(_ session: Session, state: SessionActivityState,
                                             reason: SessionAttentionReason = .input, continuesEpisode: Bool = false) {
        let changed = session.activityState != state
        let changedMeaning = state == .attention && session.attentionReason != reason
        // An idle reminder describes the finished turn, including its viewed
        // acknowledgement. A permission prompt is a new decision and episode.
        let sameWait = continuesEpisode && !changed && state == .attention
            && session.attentionReason == .completion && reason == .input
        if changed || changedMeaning {
            if !sameWait { onSessionWaitingEnded(session.id) }
            if state == .attention {
                if !sameWait { session.notificationEpisode += 1 }
                session.notificationPhase = "turn"
                session.attentionReason = reason
            }
            session.activityState = state
            if state == .attention {
                onSessionAlert(session.id, reason == .completion ? .completed : reason == .failure ? .failure : .attention)
            }
        }
    }

    /// The workspace + pane holding the session with `id`, or nil. One DFS
    /// per workspace, stopping at the first hit.
    func location(ofSessionId id: UUID) -> (workspace: Workspace, pane: Pane)? {
        for workspace in workspaces {
            if let pane = workspace.root.pane(containingSessionId: id) {
                return (workspace, pane)
            }
        }
        return nil
    }

    func takeShellCommand(sessionId: UUID, shellPID: pid_t) -> String? {
        hookSession(id: sessionId)?.takeShellCommand(shellPID: shellPID)
    }

    private func findSession(id: UUID) -> Session? {
        location(ofSessionId: id)?.pane.tabs.first { $0.id == id }
    }

    /// A hook-socket message's target session, or `nil` once `terminate()`
    /// has run — from then on AgentPad itself is killing the engines, so hook
    /// traffic is a teardown echo. On ⌘Q the drain waits for the SIGHUP'd
    /// agent to exit with the socket still listening, and the agent's own
    /// shutdown hook pings `ended`; applied, that reverts the tab to
    /// `.terminal` and the post-drain flush persists a plain terminal, so
    /// the next launch neither relaunches nor resumes it (#70). Exit callbacks
    /// from the terminal stream enforce the same boundary: PTY IO stays alive
    /// until foreground shutdown finishes.
    private func hookSession(id: UUID) -> Session? {
        guard !isTerminated, let session = findSession(id: id), session.hasProcess else { return nil }
        return session
    }

    /// Re-resolves every live session's `agent` against the current templates.
    ///
    /// `Session.agent` is a value snapshot taken at spawn, so a Settings edit
    /// to a custom agent — importing a logo, renaming it — reaches new tabs
    /// but never the ones already open. Matched by id, so a session keeps its
    /// identity; `.terminal` and sessions whose agent no longer exists are
    /// left alone. Assignment is gated on an actual change because
    /// `@Observable` notifies every tab/sidebar observer even on a same-value
    /// write, and this runs on every settings save.
    func refreshAgentTemplates() {
        let byId = Dictionary(
            AgentTemplate.all.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for workspace in workspaces {
            for pane in workspace.root.allPanes {
                for session in pane.tabs {
                    guard let fresh = byId[session.agent.id], fresh != session.agent else { continue }
                    session.agent = fresh
                }
            }
        }
    }

    @discardableResult
    func flushPersistence() -> Bool {
        pendingSave?.cancel(); pendingSave = nil
        do {
            try agentProfiles.flush()
            for session in allSessions { if let state = session.tabState { try tabCloseCoordinator.save(state) } }
            try persistence.saveChecked(terminationSnapshot ?? snapshot())
            persistenceError = nil
            return true
        } catch {
            persistenceError = error.localizedDescription
            for session in allSessions where session.tabState?.draft != nil { session.tabState?.saveError = error.localizedDescription }
            return false
        }
    }

    /// Tears the store down when its window closes — releases every
    /// session's libghostty surface + PTY (AppKit closing the `NSWindow`
    /// does not, and Swift 6's nonisolated `deinit` can't reach the
    /// `@MainActor` engine state) and stops background work. Does not
    /// mutate `workspaces` or persist — the caller decides slot retention.
    func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        navigationDragExit?.cancel()
        terminationSnapshot = snapshot()
        pendingSave?.cancel()
        pendingSave = nil
        for workspace in workspaces {
            for pane in workspace.root.allPanes {
                for tab in pane.tabs {
                    tab.engine.terminate()
                }
            }
        }
        for entry in gitWatches.values {
            entry.pendingStatusRefresh?.cancel()
            entry.watcher.cancel()
        }
        gitWatches.removeAll()
        sessionGitWatch.removeAll()
        codexUsageMonitor.stopAll()
        kiroConversationMonitor.stopAll(removeRecords: true)
        fileTree.cancel()
    }

    // MARK: - Internals

    private func pane(containing session: Session, in workspace: Workspace) -> Pane? {
        workspace.root.pane(containingSessionId: session.id)
    }

    private func restore(from state: PersistedState) {
        let fm = FileManager.default
        for ws in state.workspaces {
            let sshHost = Self.normalizedSSHHost(ws.sshRemoteHost)
            guard let root = restorePane(ws.root, fm: fm, sshRemoteHost: sshHost) else { continue }
            let workspace = Workspace(
                id: ws.id,
                workingDirectory: URL(fileURLWithPath: ws.workingDirectoryPath),
                root: root
            )
            workspace.customTitle = ws.customTitle
            workspace.worktreeParentId = ws.worktreeParentId
            workspace.worktreeBranch = ws.worktreeBranch
            workspace.worktreePath = ws.worktreePath.map { URL(fileURLWithPath: $0) }
            workspace.sshRemoteHost = sshHost
            // Exactly one of the two colour fields is ever written, so each
            // maps to its own case. An unknown preset (a colour a newer AgentPad
            // added, seen by an older build) restores untagged rather than
            // becoming a custom tag whose hex is the literal string `teal`,
            // which would render gray and read as a colour the user picked.
            // Both paths lose the value on the next save, since the encoder
            // re-derives every field from the model — preserving it would mean
            // echoing back unmapped fields, which isn't worth the machinery for
            // a downgrade-only case.
            if let preset = ws.tagPreset.flatMap(WorkspaceColorTag.init(rawValue:)) {
                workspace.tag = WorkspaceTag(color: .preset(preset), name: ws.tagName)
            } else if let hex = ws.tagCustomHex {
                workspace.tag = WorkspaceTag(color: .custom(hex: hex), name: ws.tagName)
            }
            // Wire engines now that workspace is constructed (engines need
            // the workspace ref for cwd-sync callbacks).
            for pane in workspace.root.allPanes {
                for session in pane.tabs {
                    configureSession(session, in: workspace, codexRolloutId: session.resumedConversationId)
                }
            }
            if let id = ws.activePaneId, workspace.root.allPanes.contains(where: { $0.id == id }) {
                workspace.activePaneId = id
            } else {
                workspace.activePaneId = workspace.root.firstPane?.id
            }
            workspaces.append(workspace)
        }
        activeWorkspaceId = workspaces.contains(where: { $0.id == state.activeWorkspaceId })
            ? state.activeWorkspaceId
            : workspaces.first?.id
        let legacyContent = state.sidebarSelectedContent.flatMap(SidebarContent.init(rawValue:)) ?? state.sidebarContent
        leftNavigation = state.leftNavigation ?? .migrate(mode: state.sidebarMode, content: legacyContent)
        rightSidebarMode = state.rightSidebarDefault115Applied == true ? (state.rightSidebarMode ?? .hidden) : .hidden
        chatSidebarPreferences = state.chatSidebarPreferences ?? ChatSidebarPreferences()
        chatSidebarPreferences.width = ChatSidebarPreferences.clampWidth(chatSidebarPreferences.width)
        rightSidebarContent = state.rightSidebarContent ?? .agents
        sidebarWidth = state.sidebarWidth
            .map { SidebarView.clampWidth(CGFloat($0)) }
            ?? LeftNavigationLayout.defaultPanelWidth
        rightSidebarWidth = state.rightSidebarWidth
            .map { AgentOverviewSidebar.clampWidth(CGFloat($0)) }
            ?? AgentOverviewSidebar.fullWidth
        collapsedInfoSections = Set(state.collapsedInfoSections ?? [])
        scheduleAgentProfileAdoption()
        if state.leftNavigation == nil { scheduleSave() }
    }

    private func restorePane(_ persisted: PersistedPaneNode, fm: FileManager, sshRemoteHost: String? = nil) -> PaneNode? {
        switch persisted.kind {
        case .pane(let p):
            let pane = Pane(id: p.id)
            for tab in p.tabs {
                if case .tool(let route) = tab.content {
                    pane.tabs.append(makeToolSession(route, id: tab.id, navigation: tab.navigation ?? TabNavigation(), cwd: resolvedSpawnCwd(tab.currentDirectoryPath)))
                    continue
                }
                // AgentPad: a channel tab comes back without a terminal process.
                if let channel = tab.channel {
                    pane.tabs.append(makeChannelSession(channel, id: tab.id, cwd: resolvedSpawnCwd(tab.currentDirectoryPath)))
                    continue
                }
                // AgentPad: restore native saved-list tabs without a process.
                if let inbox = tab.inbox {
                    pane.tabs.append(makeInboxSession(inbox, id: tab.id, cwd: resolvedSpawnCwd(tab.currentDirectoryPath)))
                    continue
                }
                // Presets are absent from AgentTemplate.all; even hidden ones
                // must restore their saved shell tabs instead of agent recovery.
                let agent = profileTemplates().first { $0.id == tab.agentId }
                    ?? AgentTemplate.builtin(id: tab.agentId)
                    ?? AgentPadSettingsModel.shared.terminalPresets.first { $0.id == tab.agentId }
                        .map(AgentTemplate.fromTerminalPreset)
                let recordedOrigin = tab.launchOrigin ?? tab.conversationId.flatMap {
                    agentProfiles.details.archive.origins["\(agent?.rosterId ?? tab.agentId):\($0)"]
                }
                let binding = tab.conversationId.flatMap {
                    (recordedOrigin == nil && tab.profileOriginalCwd == nil) ? nil : agentProfiles.binding(agentID: agent?.rosterId ?? tab.agentId, conversationID: $0)
                }
                let profileID = binding?.profileID ?? tab.profileID
                let savedProfile = profileID.flatMap(agentProfiles.profile)
                // Old versions could leave a Codex profile on a tab now running Claude.
                let profile = savedProfile.flatMap { profile in
                    if let agent { return profile.templateID == agent.id && profile.rosterID == agent.rosterId ? profile : nil }
                    return profile.templateID == tab.agentId ? profile : nil
                }
                // Legacy tabs retain their recorded agent ID, without inventing
                // a fingerprint from today's template. Shells have no agent origin.
                let origin = agent?.isShell == true ? nil : recordedOrigin
                if origin == nil, agent == nil {
                    let recovery = makeToolSession(.allSessions, id: tab.id, cwd: resolvedSpawnCwd(tab.currentDirectoryPath))
                    recovery.unavailableTab = tab
                    pane.tabs.append(recovery)
                    continue
                }
                let invalidOrigin = origin.map { origin in agent.map { !origin.matches($0) } ?? true } ?? false
                let needsProfile = profileID != nil && (savedProfile == nil || profile != nil)
                let profileCwd = savedProfile == nil || profile != nil ? tab.profileOriginalCwd : nil
                let pinnedCwd = binding?.record.cwd ?? origin?.folder ?? profileCwd
                let originalCwd = pinnedCwd ?? resolvedSpawnCwd(tab.currentDirectoryPath)
                if invalidOrigin || needsProfile && (!isDirectory(originalCwd) || profile == nil || agent == nil) {
                    let unavailable = makeToolSession(.unavailable(tab.id), id: tab.id, cwd: originalCwd)
                    unavailable.unavailableTab = tab
                    let message = !isDirectory(originalCwd)
                        ? ResumeRefusal.missingFolder(originalCwd.path).message(agentId: tab.agentId, conversationId: tab.conversationId ?? "")
                        : "This agent type is no longer available. Check Settings → Agents."
                    unavailable.tabState?.message = message
                    if let id = profileID { agentProfileErrors[id] = message }
                    pane.tabs.append(unavailable)
                    continue
                }
                let session = spawnSession(
                    template: agent ?? .terminal,
                    initialCwd: pinnedCwd ?? resolvedSpawnCwd(tab.currentDirectoryPath),
                    sessionId: tab.id,
                    conversationId: tab.conversationId,
                    sshRemoteHost: profile == nil ? (tab.sshWorkspaceHost.map(Self.normalizedSSHHost) ?? sshRemoteHost) : nil,
                    profile: profile, launchOrigin: origin, captureOrigin: false,
                    adoptionCwd: origin?.folder ?? tab.profileOriginalCwd ?? URL(fileURLWithPath: tab.currentDirectoryPath)
                )
                session.customTitle = tab.customTitle
                pane.tabs.append(session)
            }
            pane.activeTabId = pane.tabs.contains(where: { $0.id == p.activeTabId })
                ? p.activeTabId
                : pane.tabs.first?.id
            return PaneNode(pane: pane)
        case .split(let orientation, let first, let second, let fraction):
            guard let firstChild = restorePane(first, fm: fm, sshRemoteHost: sshRemoteHost),
                  let secondChild = restorePane(second, fm: fm, sshRemoteHost: sshRemoteHost) else { return nil }
            return PaneNode(
                id: persisted.id,
                content: .split(
                    orientation: orientation,
                    first: firstChild,
                    second: secondChild,
                    fraction: fraction
                )
            )
        }
    }

    // AgentPad: channel tabs (probe V1).
    private func makeChannelSession(_ ref: ChannelRef, id: UUID = UUID(), cwd: URL) -> Session {
        let session = Session(id: id, engine: ChannelTabEngine(ref: ref), currentDirectory: cwd, agent: .terminal)
        session.channel = ref
        holdChannelClose(session)
        return session
    }

    /// A channel tab's own Close goes to the store that holds it now: set
    /// when it is made here and again when it moves here (review F2b-p2-3).
    private func holdChannelClose(_ session: Session) {
        if let engine = session.engine as? NativeTabEngine {
            engine.owner = self
            engine.state.confirmation.canShow = { [weak engine] in
                guard let engine, let owner = engine.owner else { return false }
                return owner.isOnScreen && owner.active?.activeSession?.id == engine.tabID && engine.view.window?.isKeyWindow == true
            }
            engine.state.confirmation.restoreFocus = { [weak engine] in engine?.focus() }
            engine.state.changed = { [weak engine] in engine?.owner?.scheduleSave() }
            engine.state.confirmation.reveal = { [weak engine] in
                guard let engine, let owner = engine.owner,
                      let location = owner.location(ofSessionId: engine.tabID),
                      let session = location.pane.tabs.first(where: { $0.id == engine.tabID }) else { return false }
                location.workspace.zoomedPaneId = nil
                owner.activateWorkspace(location.workspace); owner.activateTab(session, in: location.workspace)
                TabRouter.shared.revealWindow(owner)
                return true
            }
        }
        let close: () -> Void = { [weak self, weak session] in
            guard let self, let session,
                  let workspace = self.workspaces.first(where: { ws in ws.root.allPanes.contains { $0.tabs.contains { $0 === session } } })
            else { return }
            self.closeTab(session, in: workspace)
        }
        if let engine = session.engine as? ChannelTabEngine {
            engine.conversation.tabID = session.id
            engine.onClose = close
            engine.conversation.confirmation.canShow = { [weak self, weak session, weak engine] in
                guard let self, let session, let engine else { return false }
                return self.isOnScreen && self.active?.activeSession === session && engine.view.window?.isKeyWindow == true
            }
            engine.conversation.confirmation.restoreFocus = { [weak engine] in
                guard let engine, engine.conversation.confirmation.canShow() else { return }
                engine.conversation.model?.focusRequest = ChatFocusRequest(area: .feed)
            }
            engine.conversation.confirmation.reveal = { [weak self, weak session] in
                guard let self, let session, let location = self.location(ofSessionId: session.id) else { return false }
                location.workspace.zoomedPaneId = nil
                self.activateWorkspace(location.workspace); self.activateTab(session, in: location.workspace)
                TabRouter.shared.revealWindow(self)
                return true
            }
        }
        if let engine = session.engine as? ChatInboxTabEngine {
            engine.onClose = close
            let ref = engine.ref
            engine.openMessage = { [weak self] message in
                guard let self else { return }
                ChatInboxNavigation.open(message, ref: ref, org: ChatOrgCurrent.shared.model, workspace: self)
            }
            engine.openChannel = { [weak self] channel in
                let org = ChatOrgCurrent.shared.model
                guard case .ready = ref.state(org), let key = org?.key, org?.visibleChannel(channel) != nil else { return }
                self?.showChannel(ChannelRef(key, channel: channel))
            }
        }
    }

    // AgentPad: inbox tabs share the normal tab lifecycle and current owner.
    private func makeInboxSession(_ ref: ChatInboxRef, id: UUID = UUID(), cwd: URL) -> Session {
        let session = Session(id: id, engine: ChatInboxTabEngine(ref: ref), currentDirectory: cwd, agent: .terminal)
        session.inbox = ref
        holdChannelClose(session)
        return session
    }

    @discardableResult
    func showInbox(_ ref: ChatInboxRef) -> Session? {
        for workspace in workspaces {
            if let session = workspace.root.allPanes.flatMap(\.tabs).first(where: { $0.inbox == ref }) {
                activateWorkspace(workspace); activateTab(session, in: workspace)
                return session
            }
        }
        guard let workspace = active ?? workspaces.first else { return nil }
        return openInboxTab(ref, in: workspace)
    }

    @discardableResult
    func openInboxTab(_ ref: ChatInboxRef, in workspace: Workspace, pane: Pane? = nil) -> Session {
        invalidateTabConfirmations()
        guard let target = pane ?? workspace.activePane ?? workspace.root.firstPane else { preconditionFailure("workspace has no panes") }
        let session = makeInboxSession(ref, cwd: workspace.workingDirectory)
        configureSession(session, in: workspace, codexRolloutId: nil)
        target.tabs.append(session); target.activeTabId = session.id; workspace.activePaneId = target.id
        scheduleSave()
        return session
    }

    /// The tab of `ref` in this window, the whole ref compared (review F2b-3).
    func channelTab(_ ref: ChannelRef) -> (Session, Workspace)? {
        for workspace in workspaces {
            for pane in workspace.root.allPanes {
                if let session = pane.tabs.first(where: { $0.channel == ref }) { return (session, workspace) }
            }
        }
        return nil
    }

    /// Brings `ref`'s tab forward, or opens one in the active workspace.
    @discardableResult
    func showChannel(_ ref: ChannelRef, newTab: Bool = false) -> Session? {
        if !newTab, let (session, workspace) = channelTab(ref) {
            activateWorkspace(workspace)
            activateTab(session, in: workspace)
            return session
        }
        guard let workspace = active ?? workspaces.first else { return nil }
        return openChannelTab(ref, in: workspace)
    }

    @discardableResult
    func openChannelTab(_ ref: ChannelRef, in workspace: Workspace, pane: Pane? = nil) -> Session {
        invalidateTabConfirmations()
        guard let target = pane ?? workspace.activePane ?? workspace.root.firstPane else {
            preconditionFailure("workspace has no panes")
        }
        let session = makeChannelSession(ref, cwd: workspace.workingDirectory)
        configureSession(session, in: workspace, codexRolloutId: nil)
        target.tabs.append(session)
        target.activeTabId = session.id
        if workspace.activePaneId != target.id { workspace.activePaneId = target.id }
        session.lastActivated = Date()
        scheduleSave()
        return session
    }

    /// Spawns the engine + Session. Caller wires `onPwdChange` / `onFocus`
    /// after a workspace ref is available — `restore` builds sessions before
    /// the workspace exists, so callbacks can't capture it here.
    private func spawnSession(template: AgentTemplate, initialCwd: URL, sessionId: UUID = UUID(), conversationId: String? = nil, forceResume: Bool = false, claudeResolution: Result<String, ClaudeSessionResume.Refusal>? = nil, initialPrompt: String? = nil, sshRemoteHost: String? = nil, rawLaunchCommand: String? = nil, customTitle: String? = nil, spawnInBackground: Bool = false, profile: AgentProfile? = nil, launchOrigin: AgentLaunchOrigin? = nil, captureOrigin: Bool = true, adoptionCwd: URL? = nil) -> Session {
        let engine = engineFactory()
        // Before `engine.start` (and before any view mounts): the flag is
        // what lets the surface come up under a hidden mount (issue #59).
        engine.spawnsWhileHidden = spawnInBackground
        let extraOptions = launchOrigin?.options ?? profile.flatMap { $0.templateID == template.id ? $0.launchOptions : nil } ?? optionsProvider(template.id)
        let persistsConversation = template.persistsConversation(extraOptions: extraOptions)
        // Resume gated by user setting — `resumeConversations` flips this off
        // when the user wants every agent tab to start fresh without
        // losing the persisted conversation id (it stays on disk so the
        // setting can be flipped back on later). Plain shells ignore the value
        // through `makeSessionConfig`, so we don't have to re-check here.
        // `forceResume` bypasses the gate: picking a session from the History
        // list is an explicit ask, not the automatic relaunch the setting
        // exists to switch off.
        let visibility = conversationVisibility()
        var normalizedConversationId = persistsConversation
            ? template.normalizedConversationId(conversationId)
            : nil
        let resumeId = (forceResume || resumeProvider()) ? normalizedConversationId : nil
        var checkedResumeId = resumeId
        var resolution = claudeResolution
        if template.rosterId == AgentTemplate.claudeCodeID, let id = resumeId {
            resolution = resolution ?? ClaudeSessionResume.resolve(id, root: claudeProjectsRoot, visibility: visibility)
            checkedResumeId = try? resolution?.get()
            normalizedConversationId = checkedResumeId
        }
        // Grok accepts a caller-assigned UUID for a fresh session. Generate it
        // before launch and persist the same value immediately, eliminating
        // the hook/file-discovery race every other agent has to solve. When
        // resume is disabled, an existing saved id deliberately gets replaced
        // with a new one so this launch starts fresh.
        let newSessionId: String?
        if persistsConversation, resumeId == nil, template.preallocatesConversationId {
            let id = UUID().uuidString
            normalizedConversationId = id
            newSessionId = id
        } else {
            newSessionId = nil
        }
        // The template owns SSH composition (agentpad-ssh wrapping, dropping the
        // local-only resume id, forcing a wrapped shell) — see
        // `makeSessionConfig(sshHost:)`.
        let sshHost = Self.normalizedSSHHost(sshRemoteHost)
        var config = template.makeSessionConfig(
            extraOptions: extraOptions,
            resumeId: resumeId,
            newSessionId: newSessionId,
            initialPrompt: initialPrompt,
            sshHost: sshHost,
            rawLaunchCommand: rawLaunchCommand,
            claudeProjectsRoot: claudeProjectsRoot,
            visibility: visibility,
            claudeResolution: resolution
        )
        config.workingDirectory = initialCwd.path
        // A Claude-Code-based custom agent with an env block hands `claude`
        // its endpoint / key via a per-agent Claude settings file (written by
        // `refreshClaudeCustomSettings`); `agentPadEnvironment` routes this
        // session's AGENTPAD_HOOKS_PATH there.
        let claudeCustomId = template.baseAgentId == AgentTemplate.claudeCodeID && !template.extraEnv.isEmpty
            ? template.id : nil
        config.environment.merge(
            AgentPadShellIntegration.agentPadEnvironment(for: sessionId, claudeCustomSettingsAgentId: claudeCustomId)
        ) { _, new in new }
        let launchID = sshHost == nil && config.environment["AGENTPAD_AGENT"] != nil ? UUID() : nil
        config.environment["AGENTPAD_LAUNCH_ID"] = launchID?.uuidString
        engine.start(config: config)
        // Mirror the command-line gates: SSH/raw commands carry no local
        // resume ID, and a non-empty prompt starts a fresh conversation.
        let promptSuppressesResume = !(initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let resumedConversationId = (sshHost == nil && rawLaunchCommand == nil && !promptSuppressesResume && template.supportsResume)
            ? checkedResumeId : nil
        let session = Session(
            id: sessionId,
            engine: engine,
            currentDirectory: initialCwd,
            agent: template,
            customTitle: customTitle,
            conversationId: normalizedConversationId,
            launchedConversationId: (sshHost == nil && rawLaunchCommand == nil) ? resumedConversationId ?? newSessionId : nil,
            profileAdoption: !template.isShell && sshHost == nil && !template.rosterId.isEmpty
                ? AgentProfileAdoption.Candidate(tabID: sessionId, rosterID: template.rosterId,
                    templateID: launchOrigin?.templateID ?? template.id, launchOptions: extraOptions ?? "",
                    folder: launchOrigin?.folder ?? adoptionCwd ?? initialCwd, conversationID: conversationId ?? newSessionId,
                    title: customTitle ?? initialCwd.lastPathComponent, createdAt: Date()) : nil
        )
        // Resuming an unprovenanced conversation cannot prove its original
        // launch configuration. Only a fresh conversation captures new evidence.
        session.launchOrigin = launchOrigin ?? ((captureOrigin && conversationId == nil && !template.isShell && sshHost == nil && rawLaunchCommand == nil)
            ? AgentLaunchOrigin(template: template, folder: initialCwd, options: extraOptions ?? "") : nil)
        session.profileID = profile?.id
        session.profileOriginalCwd = profile == nil ? nil : initialCwd
        session.pendingAgentLaunch = launchID.map { ($0, !template.isShell) }
        session.resumedConversationId = resumedConversationId
        session.spawnsInBackground = spawnInBackground
        if let sshHost {
            session.sshWorkspaceHost = sshHost
            // Optimistic: the remote shim's `running` marker confirms once
            // the connection + rc replay settle; until then the tab already
            // reads as "agent starting", matching the local launch feel.
            if !template.isShell { session.activityState = .running }
        }
        return session
    }

    /// Trimmed, non-empty SSH destination or nil. Single gate for every
    /// entry point (create sheet, persistence restore, spawn) so a
    /// whitespace-only host can never mark a workspace remote. Same
    /// blank-collapses-to-nil rule as titles — one rule, one place.
    static func normalizedSSHHost(_ raw: String?) -> String? {
        raw.flatMap(normalizedTitle)
    }

    /// `codexRolloutId` is the id of the rollout file this session ALREADY
    /// has on disk, nil when none exists yet — it steers the Codex usage
    /// monitor's file resolution. Spawn-path callers pass
    /// `session.resumedConversationId` (the post-gate value `spawnSession`
    /// put on the command line — re-deriving `resumeProvider() ?
    /// conversationId : nil` would miss a forced History-list resume);
    /// the cross-window attach path passes `session.conversationId` instead,
    /// because a live Codex tab's rollout predates the DESTINATION store's
    /// monitor snapshot and would otherwise be excluded as another session's
    /// file. AgentPad: this preserves the source monitor's heuristic; it is not
    /// a verified journal binding for answer export.
    private func configureSession(_ session: Session, in workspace: Workspace, codexRolloutId: String?) {
        guard session.hasProcess else { holdChannelClose(session); return }
        // Initial refresh — without these, the status bar stays empty until
        // the user `cd`s or runs a command. Both fetchers silently hide
        // results for non-applicable cwds, so the calls are harmless.
        updateGitWatch(for: session)
        refreshGitStatus(for: session)
        refreshEnvironment(for: session)
        startCodexUsageIfNeeded(
            for: session,
            resumingConversationId: codexRolloutId
        )
        startKiroConversationIfNeeded(for: session)
        wireSessionCallbacks(engine: session.engine, session: session, workspace: workspace)
    }

    /// Retarget engine events without restarting session-owned monitors.
    private func wireSessionCallbacks(engine: any TerminalEngine, session: Session, workspace: Workspace) {
        guard session.hasProcess else { holdChannelClose(session); return }
        session.terminalConfirmation.canShow = { [weak self, weak session] in
            guard let self, let session, self.active?.activeSession === session,
                  let window = session.engine.view.window else { return false }
            return window.isVisible && window.isKeyWindow && !session.engine.view.isHiddenOrHasHiddenAncestor
        }
        session.terminalConfirmation.reveal = { [weak self, weak session] in
            guard let self, let session, let location = self.location(ofSessionId: session.id) else { return false }
            self.activateWorkspace(location.workspace); self.activateTab(session, in: location.workspace)
            TabRouter.shared.revealWindow(self)
            return true
        }
        (engine.view as? GhosttySurfaceView)?.confirmationSession = session
        // Paste-time upload routing. Deliberately `sshWorkspaceHost` (spawn
        // pinned), NOT `remoteHost`: the latter is the status-bar display
        // signal with a marker→command-finished lifecycle that a remote
        // shell's own OSC 133;D can clear mid-connection.
        engine.pasteUploadHostProvider = { [weak session] in session?.sshWorkspaceHost }
        // File paths printed by an SSH shell live on the remote machine. Keep
        // ordinary web links openable, but prevent Cmd+Click from treating a
        // remote absolute path as a coincidentally-existing local file.
        engine.isRemoteSessionProvider = { [weak session] in
            session?.sshWorkspaceHost != nil || session?.remoteHost != nil
        }
        engine.onOpenFile = { [weak self, weak session, weak workspace] reference in
            guard let self, let session, let workspace else { return }
            self.activateWorkspace(workspace)
            self.activateTab(session, in: workspace)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: reference.url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                self.revealFileTree(root: reference.url)
            } else {
                FilePreviewModel.for(self).open(reference.url, line: reference.line, column: reference.column)
            }
        }
        engine.onPwdChange = { [weak self, weak session, weak workspace] pwd in
            guard let session else { return }
            let url = URL(fileURLWithPath: pwd)
            // Compare against the URL's normalized path (what actually gets
            // stored) — not raw `pwd` — so a shell that reports a trailing-slash
            // cwd doesn't read as a change every prompt and defeat the gate below.
            let path = url.path
            let cwdChanged = session.currentDirectory.path != path
            if cwdChanged {
                session.currentDirectory = url
            }
            var workspaceCwdChanged = false
            if let workspace, workspace.activeSession?.id == session.id, workspace.workingDirectory.path != path {
                workspace.workingDirectory = url
                workspaceCwdChanged = true
            }
            // Git status AND the watcher hub refresh on EVERY prompt, even an
            // unchanged cwd — neither is safe to gate on cwdChanged:
            //  • refreshGitStatus: an external editor can change the working
            //    tree's uncommitted-file count without touching .git, which the
            //    watcher's fs source never sees; this per-prompt fetch (which
            //    result-dedups) is the only catch.
            //  • updateGitWatch: its per-prompt re-probe is what finally
            //    attaches a watcher when a repo is created in place
            //    (`git init` / `clone .`) with no cd. Gating it would strand
            //    that case (issue #29 review). Unchanged-cwd prompts inside a
            //    repo cost two dictionary hits, no filesystem walk.
            self?.updateGitWatch(for: session)
            self?.refreshGitStatus(for: session)
            // Environment + persistence DO only move with the cwd. venv / node
            // changes are pushed by the separate `_agentpad_env_status` precmd IPC
            // (which updates shellEnvironment → refreshEnvironment), and the only
            // state this closure persists is the two cwd fields — so on an
            // unchanged cwd both refreshEnvironment and scheduleSave are redundant.
            if cwdChanged {
                self?.refreshEnvironment(for: session)
            }
            if cwdChanged || workspaceCwdChanged {
                self?.scheduleSave()
            }
        }
        engine.onTitleChange = { [weak self, weak session] title in
            guard let self, !self.isTerminated, let session else { return }
            if session.consumeShellControlTitle(title) { return }
            if title.hasPrefix(AgentLaunchExitMarker.prefix) {
                if let result = AgentLaunchExitMarker.parse(title),
                   let launch = session.pendingAgentLaunch, launch.id == result.id {
                    let ranAgent = launch.isAgent || session.awaitingAgentExitOutcome || session.transientAgent != nil || !session.agent.isShell
                    session.pendingAgentLaunch = nil
                    session.reportedAgentLaunchExit = true
                    self.finishShellCommand(session, exit: result.exit, duration: 0, ranAgent: ranAgent)
                }
                return
            }
            // A `agentpad-command:*` title is the preexec-reported command line,
            // not a visible title. Checked first: it's by far the most frequent
            // marker (one per command). Riding this stream rather than the
            // socket is what guarantees it lands before the OSC 133;D result it
            // labels — see `CommandMarker`.
            if let command = CommandMarker.parseTitle(title) {
                session.reportedAgentLaunchExit = false
                session.lastCommandText = command
                return
            }
            // A `agentpad-remote-login:*` title is an ssh-destination marker, not
            // a visible title — record the host and stop before it reaches
            // `terminalTitle`. Cleared ONLY by the wrapper's logout marker
            // below: OSC 133;D is not "ssh exited" (a remote shell's own
            // integration emits it per remote command, through the wire).
            if let host = RemoteLoginMarker.parseTitle(title) {
                session.remoteHost = host
                // The local preexec reported `ssh host`, but OSC 133 results
                // arriving after this marker belong to commands inside the
                // remote shell. Drop the local command label rather than pair
                // it with an unrelated remote exit code.
                session.lastCommandText = nil
                return
            }
            if RemoteLoginMarker.isLogoutTitle(title) {
                session.remoteHost = nil
                return
            }
            // Any `agentpad-agent:*` title is a status marker, never a visible
            // title — consume it (applying the agent state when it resolves to
            // a known agent) and stop before it reaches `terminalTitle`.
            if AgentStatusMarker.isMarkerTitle(title) {
                if let marker = AgentStatusMarker.parseTitle(title) {
                    self.applyAgentStatusMarker(
                        agent: marker.agent,
                        event: marker.event,
                        session: session
                    )
                }
                return
            }
            // A path-shaped SET_TITLE is noise: libghostty synthesises one
            // from OSC 7, and the wrapper re-emits the cwd each prompt — both
            // are things `Session.title` already renders. Keep only what the
            // cwd can't say (`ssh`'s `user@host:dir`, a TUI's filename).
            let next = normalizedTitle(title).flatMap {
                ($0.hasPrefix("/") || $0.hasPrefix("~")) ? nil : $0
            }
            session.applyTerminalTitle(next)
        }
        engine.onFocus = { [weak self, weak session, weak workspace] in
            guard let self, let session, let workspace else { return }
            self.activateTab(session, in: workspace)
        }
        engine.onCommandFinished = { [weak self, weak session] exit, duration in
            guard let self, !self.isTerminated, let session,
                  session.pendingAgentLaunch == nil, !session.reportedAgentLaunchExit else { return }
            let ranAgent = session.awaitingAgentExitOutcome || session.transientAgent != nil
                || (!session.agent.isShell && session.hookStateAt != .distantPast)
            self.finishShellCommand(session, exit: exit, duration: duration, ranAgent: ranAgent)
        }
        engine.onUserInput = { [weak session] in
            // libghostty exposes no command-START, so a keystroke (the first
            // character of the next command) is when we clear a stale
            // command-failure dot — covers any command, agent or manual.
            guard let session, session.lastCommandExit != nil else { return }
            session.lastCommandExit = nil
            session.lastCommandDuration = nil
            // Do not let a failed/missing command hook pair the next OSC 133
            // result with stale text from the previous command. Its preexec
            // report will repopulate this before the new result arrives.
            session.lastCommandText = nil
        }
        engine.onProcessExitedCleanly = { [weak self, weak session, weak workspace] in
            guard let self, !self.isTerminated, let session, let workspace else { return }
            self.closeTab(session, in: workspace)
        }
        engine.onDesktopNotification = { [weak self, weak session] title, body in
            guard let self, !self.isTerminated, let session else { return }
            session.programNotificationEpisode += 1
            self.onSessionAlert(session.id, .programNotification(title: title, body: body))
        }
        engine.onLinkHover = { [weak session] url in
            session?.hoveredLinkURL = url
        }
        engine.onSearchStart = { [weak session] needle in
            guard let session else { return }
            session.searchActive = true
            session.searchNeedle = needle
            session.searchTotal = 0
            session.searchSelected = -1
        }
        engine.onSearchEnd = { [weak session] in
            guard let session else { return }
            session.searchActive = false
            session.searchNeedle = ""
            session.searchTotal = 0
            session.searchSelected = -1
        }
        engine.onSearchTotal = { [weak session] total in
            guard let session, session.searchTotal != total else { return }
            session.searchTotal = total
        }
        engine.onSearchSelected = { [weak session] selected in
            guard let session, session.searchSelected != selected else { return }
            session.searchSelected = selected
        }
    }

    private func finishShellCommand(_ session: Session, exit: Int?, duration: TimeInterval, ranAgent: Bool) {
        // A remote agent surfaced via an OSC marker (transientAgent) emits
        // no `ended` marker when the ssh drops abnormally (network loss,
        // killed connection), so command-finished stays its safety net.
        // Safe even though a REMOTE shell integration's 133;D also lands
        // here: while a remote agent runs it owns the remote foreground,
        // so no remote prompt (hence no D) can fire mid-agent.
        // `remoteHost` is different — it must survive remote-command D's
        // for the whole connection, so it's cleared by the wrapper's
        // logout marker in onTitleChange, NOT here.
        if session.transientAgent != nil {
            session.transientAgent = nil
            session.activityState = .idle
        }
        // Codex blocks the shell while it runs, so this firing means Codex
        // exited (or any other command finished) — drop the usage gauge and
        // stop watching the now-static rollout. Reliable even on an abnormal
        // codex exit where the `ended` hook never fires, since the shell
        // always returns to the prompt. stop() is unconditional (a true
        // no-op for sessions that never started a watcher) so it also frees
        // the fd when codex exited before its first `token_count` — e.g. an
        // auth failure or `codex --help`, where `codexUsage` stayed nil.
        if session.codexUsage != nil { session.codexUsage = nil }
        self.codexUsageMonitor.stop(sessionId: session.id)
        // Kiro has returned control to the shell too, so its full ACP
        // trace is now static and can be removed after the id was saved.
        self.kiroConversationMonitor.stop(sessionId: session.id, removeRecord: true)
        session.lastCommandExit = exit
        session.lastCommandDuration = duration
        // Inspector snapshot — taken here (completion), NOT cleared on
        // input like the pair above. Exit-less results (a shell that
        // omits the 133;D field) are skipped, matching the old
        // `lastCommandExit != nil` display gate.
        if let exit {
            session.lastCompletedCommand = .init(
                text: session.lastCommandText,
                exit: exit,
                duration: duration
            )
        }
        // A non-zero exit on a backgrounded tab is worth a nudge;
        // AppDelegate gates on visibility + the notifications setting.
        self.onSessionWaitingEnded(session.id)
        let agentExited = ranAgent
        session.awaitingAgentExitOutcome = false
        session.notificationPhase = "exit"
        session.notificationEpisode += 1
        if let exit, exit != 0 { self.onSessionAlert(session.id, .failure) }
        else if agentExited { self.onSessionAlert(session.id, .completed) }
        if agentExited {
            session.agent = .terminal; session.activityState = .idle
            session.launchOrigin = nil
            scheduleSave()
        }
        // A finished command may have changed the working tree (commit /
        // git add / file edits) or installed a venv / dropped an .nvmrc.
        // Refresh so the bar doesn't lie.
        self.refreshGitStatus(for: session)
        self.refreshEnvironment(for: session)
    }

    private func applyAgentStatusMarker(agent: AgentTemplate, event: HookEvent, session: Session) {
        let agentBefore = session.agent.id
        if event == .ended {
            if session.transientAgent?.id == agent.id || session.transientAgent?.baseAgentId == agent.id {
                // The remote wrapper reports no exit code; a local command
                // result may arrive only when SSH closes. Complete before
                // clearing so displayAgent still resolves to the remote agent.
                handleAgentEnded(session, awaitExitOutcome: false)
                session.transientAgent = nil
            }
            if session.agent.id == agent.id || session.agent.baseAgentId == agent.id {
                session.agent = .terminal
                session.launchOrigin = nil
            }
        } else if session.agent.isShell {
            session.transientAgent = agent
        }

        applyNotificationTransition(session, state: event.activityState,
                                    reason: event == .turnComplete ? .completion : event == .turnFailure ? .failure : .input)
        if session.agent.id != agentBefore { scheduleSave() }
    }

    private func refreshGitStatus(for session: Session) {
        // Off screen nothing paints the result; `setOnScreen(true)` refetches.
        guard isOnScreen, session.hasProcess else { return }
        if let gitDir = sessionGitWatch[session.id]?.gitDir,
           gitWatches[gitDir]?.subscribers.contains(session.id) == true {
            scheduleGitStatusRefresh(for: gitDir)
        } else {
            gitStatusFetcher.fetch(id: session.id.uuidString, cwd: session.currentDirectory) { [weak session] status in
                guard let session, session.gitStatus != status else { return }
                session.gitStatus = status
            }
        }
        // Piggyback the file tree's per-file diff on the SAME triggers that
        // refresh the status bar (spawn / every prompt / command finished /
        // GitWatcher) — single chokepoint, so the tree's +/− badges and the
        // status bar's totals can never drift.
        refreshFileTreeGitDiff(ifVisibleFor: [session.id])
    }

    /// Stable dedup key for the tree's diff fetch: the tree is a per-store
    /// singleton, so a NEWER fetch must invalidate ANY older in-flight one —
    /// keying by workspace id would let a slow pre-switch fetch land after
    /// the new workspace's fresh result and blank its badges for a beat.
    private let fileTreeDiffFetchKey = "file-tree"

    /// Piggyback gate shared by every status-refresh path: refresh the
    /// tree's diff only while it is showing AND one of the event's sessions
    /// can be on screen (in the active workspace's pane tree).
    /// `refreshFileTreeGitDiff()` stays callable directly for the tree's
    /// own mount/root-change hooks.
    private func refreshFileTreeGitDiff(ifVisibleFor ids: some Sequence<UUID>) {
        guard fileTree.isShowing, let activeRoot = active?.root,
              ids.contains(where: { activeRoot.pane(containingSessionId: $0) != nil }) else { return }
        refreshFileTreeGitDiff()
    }

    /// Fetches per-file `+/−` counts for the file tree's current root and
    /// pushes them into the model. Also called by `FileTreeView` on mount
    /// and root change (the chokepoint above can't see those). Gated on the
    /// model's own mounted predicate — zero git cost while the tree isn't
    /// on screen (workspaces mode, compact, hidden sidebar).
    func refreshFileTreeGitDiff() {
        guard fileTree.isShowing, let root = fileTree.rootURL else { return }
        gitStatusFetcher.fetchFileDiffs(id: fileTreeDiffFetchKey, cwd: root) { [weak self] diffs in
            self?.fileTree.applyGitDiff(diffs)
        }
    }

    /// Diff pill's click-time refresh: the popover's numstat snapshot carries
    /// fresher totals than the last prompt-driven fetch, so fold them in
    /// through the same seams a fetch result uses — mark any in-flight fetch
    /// stale (a slower, older one must not overwrite this newer result) and
    /// re-run the file-tree badge piggyback so tree badges and pill totals
    /// can't drift (the M5.qqqq sums-by-construction invariant).
    func applyDiffSnapshot(_ diff: GitDiffSnapshot, for session: Session, cwdPath: String) {
        // Ignore a result whose world moved while git was in flight: the cwd
        // changed, or the snapshot's repo isn't the one the pill currently
        // shows (mid-`cd` across repos — the pill's branch/root still belong
        // to the old repo; let the in-flight prompt fetch land the coherent
        // new status instead of folding foreign totals into it).
        guard session.currentDirectory.path == cwdPath,
              session.gitStatus.repoRoot == diff.repoRoot else { return }
        var refreshed = session.gitStatus
        refreshed.filesChanged = diff.filesChanged
        refreshed.insertions = diff.insertions
        refreshed.deletions = diff.deletions
        if refreshed != session.gitStatus {
            // Shared broadcasts snapshot this lane and skip only this session
            // when the token moves; the other subscribers must still receive
            // the in-flight repo result.
            gitStatusFetcher.invalidateInFlight(id: session.id.uuidString)
            session.gitStatus = refreshed
        }
        // Outside the totals gate: the file-level distribution can change
        // while totals stay equal (revert a line here, add one there) — the
        // tree's badges must follow the popover's rows regardless. The
        // invalidate lifts the tree lane's 50ms coalescing window so this
        // edge-triggered refresh can never be stood in for by an older poll.
        gitStatusFetcher.invalidateInFlight(id: fileTreeDiffFetchKey)
        refreshFileTreeGitDiff(ifVisibleFor: [session.id])
    }

    /// Starts (or re-points) the Codex usage watcher for a Codex session.
    /// No-op for every other agent. Called on session wire-up (covers a tab
    /// launched as Codex or restored as one) and on the `running` lifecycle
    /// event (covers a manually-typed `codex`, and a relaunch that opens a
    /// fresh rollout file). `start` is idempotent for an unchanged resolution.
    private func startCodexUsageIfNeeded(
        for session: Session,
        resumingConversationId: String? = nil
    ) {
        let key = session.displayAgent.rosterId
        guard key == AgentTemplate.codex.id else { return }
        // Resolve CODEX_HOME from the session's live shell env (a Dock-launched
        // AgentPad doesn't inherit it; the codex child does). The monitor snapshots
        // existing rollouts on this first call to tell this session's own file
        // apart from a prior run's. AgentPad: parallel launches in the same cwd
        // remain ambiguous; this heuristic must never establish export bindings
        // or adopt a tab into a profile.
        let root = CodexUsageMonitor.sessionsRoot(shellEnv: session.shellEnvironment)
        codexUsageMonitor.start(
            sessionId: session.id,
            cwd: session.currentDirectory,
            sessionsRoot: root,
            resumingConversationId: resumingConversationId,
            conversationUpdate: { [weak self, weak session] id in
                guard let self, let session else { return }
                self.applyConversationId(conversationId: id, sessionId: session.id)
            }
        ) { [weak session] usage in
            guard let session, session.codexUsage != usage else { return }
            session.codexUsage = usage
        }
    }

    // MARK: - Git watcher hub

    /// (Re)subscribes a session to the shared watcher for its cwd's gitdir.
    /// Runs on every prompt — that per-prompt retry is what attaches a
    /// watcher once a repo appears in place — but the common unchanged-cwd
    /// prompt costs two dictionary hits and no filesystem walk.
    private func updateGitWatch(for session: Session) {
        let cwdPath = session.currentDirectory.path
        let cached = sessionGitWatch[session.id]
        if let cached, cached.cwdPath == cwdPath, let gitDir = cached.gitDir {
            // Same repo as last prompt: just confirm the shared watcher
            // still holds live kqueue fds (gitdir deleted then recreated) —
            // the per-prompt retry the old per-session watch() provided. A
            // cached "not a repo" falls through and re-probes instead: the
            // git-init-in-place attach path.
            if let watcher = gitWatches[gitDir]?.watcher, !watcher.isAttached {
                watcher.watch(cwd: session.currentDirectory)
            }
            return
        }
        let resolved = GitWatcher.findGitDir(near: session.currentDirectory)
        let gitDir = resolved?.path
        sessionGitWatch[session.id] = (cwdPath, gitDir)
        // A cd WITHIN the same repo keeps the subscription (and the fds) —
        // the old per-session watcher tore down + reopened both fds here.
        guard cached?.gitDir != gitDir else { return }
        if let previous = cached?.gitDir {
            unsubscribeGitWatch(sessionId: session.id, from: previous)
        }
        if let gitDir, let resolved {
            // A direct non-repo fetch may still be in flight from the old
            // cwd. Moving onto the shared repo lane must make that result
            // stale, otherwise a late EMPTY status can erase the repo state.
            gitStatusFetcher.invalidateInFlight(id: session.id.uuidString)
            subscribeGitWatch(session: session, to: gitDir, resolvedGitDir: resolved)
        }
    }

    private func subscribeGitWatch(session: Session, to gitDir: String, resolvedGitDir: URL) {
        let entry: GitWatch
        if let existing = gitWatches[gitDir] {
            entry = existing
        } else {
            let watcher = GitWatcher { [weak self] in
                self?.scheduleGitStatusRefresh(for: gitDir)
            }
            watcher.watch(cwd: session.currentDirectory, resolvedGitDir: resolvedGitDir)
            entry = GitWatch(watcher: watcher)
            gitWatches[gitDir] = entry
        }
        entry.subscribers.insert(session.id)
    }

    private func unsubscribeGitWatch(sessionId: UUID, from gitDir: String) {
        guard let entry = gitWatches[gitDir] else { return }
        entry.subscribers.remove(sessionId)
        if entry.subscribers.isEmpty {
            let removed = gitWatches.removeValue(forKey: gitDir)
            removed?.pendingStatusRefresh?.cancel()
            removed?.watcher.cancel()
        }
    }

    /// Test-only probe: the shared-watcher invariants (one watcher per
    /// gitdir, subscriber counting) have no UI-observable surface.
    var gitWatchHubStats: (watchers: Int, subscriptions: Int) {
        (gitWatches.count, gitWatches.values.reduce(0) { $0 + $1.subscribers.count })
    }

    /// Test-only probe for the number of actual status fetch batches (after
    /// both the shared-repo fan-in and fetcher's same-lane coalescing).
    var gitStatusDispatchCount: Int { gitStatusFetcher.statusDispatchCount }

    /// Test-only probe for the two freshness lanes touched by a click-time
    /// diff snapshot. The session lane must advance; the shared lane must not.
    func gitStatusLaneTokens(for session: Session) -> (session: Int, shared: Int?) {
        let sessionToken = gitStatusFetcher.currentToken(id: session.id.uuidString)
        let sharedToken = sessionGitWatch[session.id]?.gitDir.map {
            gitStatusFetcher.currentToken(id: $0)
        }
        return (sessionToken, sharedToken)
    }

    /// Close-site teardown: drops the session's subscription, and the shared
    /// watcher with it when this was the last subscriber.
    private func removeGitWatch(sessionId: UUID) {
        guard let gitDir = sessionGitWatch.removeValue(forKey: sessionId)?.gitDir else { return }
        unsubscribeGitWatch(sessionId: sessionId, from: gitDir)
    }

    /// Every monitor a live session holds, torn down in one place — the
    /// close paths used to hand-copy this block, and a missed line leaked
    /// kqueue fds with no UI surface. `keepForTransfer` is the cross-window
    /// surrender variant: the destination store re-wires the session, so
    /// the engine stays alive and agent records survive.
    private func teardownSessionMonitors(_ session: Session, keepForTransfer: Bool = false) {
        session.terminalConfirmation.invalidate()
        if !keepForTransfer {
            onSessionWaitingEnded(session.id)
            ChatService.shared.mcpDownloads.remove(surface: session.id.uuidString.lowercased())
        }
        removeGitWatch(sessionId: session.id)
        codexUsageMonitor.stop(sessionId: session.id)
        kiroConversationMonitor.stop(sessionId: session.id, removeRecord: !keepForTransfer)
        if !keepForTransfer { session.engine.terminate() }
    }

    /// Collects prompt/spawn/watcher triggers for one gitdir. Keeping the
    /// pending task on the shared entry makes fan-in explicit: N tabs can
    /// request refresh independently while only one batch reaches git.
    private func scheduleGitStatusRefresh(for gitDir: String) {
        guard let entry = gitWatches[gitDir], entry.pendingStatusRefresh == nil else { return }
        entry.pendingStatusRefresh = Task { @MainActor [weak self, weak entry] in
            try? await Task.sleep(for: Self.sharedGitRefreshDelay)
            guard !Task.isCancelled, let self, let entry,
                  self.gitWatches[gitDir] === entry else { return }
            entry.pendingStatusRefresh = nil
            self.performSharedGitStatusRefresh(gitDir)
        }
    }

    /// Shared-watcher fan-out. ONE git run per repo event/prompt burst, its result
    /// broadcast to every subscribed session — same gitdir means same HEAD
    /// and same working tree, so their statuses are identical by
    /// construction. This is what turns "ten tabs on one repo, one commit"
    /// from ten fetches (twenty forks) into one fetch. The gitdir path
    /// doubles as the fetch lane key. Every new trigger waits 60ms after the
    /// prior dispatch, beyond the fetcher's 50ms coalescing window, so a
    /// genuinely later burst cannot be swallowed by the previous batch.
    private func performSharedGitStatusRefresh(_ gitDir: String) {
        // GitWatcher-driven path; the prompt-driven one is gated in
        // `refreshGitStatus`. Off screen nothing paints the result.
        guard let entry = gitWatches[gitDir], isOnScreen else { return }
        var anchor: Session?
        for id in entry.subscribers {
            guard let session = findSession(id: id) else { continue }
            // Skip sessions whose cwd was deleted under them (shell still
            // parked there): `git -C <gone>` fails and would broadcast an
            // EMPTY status over every healthy tab. Their own prompt fetch
            // reports the empty state where it belongs (Codex review P2).
            if isDirectory(session.currentDirectory) { anchor = session; break }
        }
        guard let anchor else { return }
        // Snapshot each subscriber's own lane at dispatch: a newer
        // out-of-band result (the click-time diff snapshot) advances that
        // lane, and this shared older result must not overwrite it.
        let laneStamps = Dictionary(uniqueKeysWithValues: entry.subscribers.map { id in
            (id, gitStatusFetcher.currentToken(id: id.uuidString))
        })
        gitStatusFetcher.fetch(id: gitDir, cwd: anchor.currentDirectory) { [weak self] status in
            // Re-read the subscriber set at completion (sessions that closed
            // mid-fetch drop out), then broadcast in ONE pane-tree pass
            // instead of a per-id tree search.
            guard let self, let ids = self.gitWatches[gitDir]?.subscribers else { return }
            for workspace in self.workspaces {
                for pane in workspace.root.allPanes {
                    for tab in pane.tabs where ids.contains(tab.id) && tab.gitStatus != status {
                        if let stamp = laneStamps[tab.id],
                           self.gitStatusFetcher.currentToken(id: tab.id.uuidString) != stamp {
                            continue
                        }
                        tab.gitStatus = status
                    }
                }
            }
        }
        refreshFileTreeGitDiff(ifVisibleFor: entry.subscribers)
    }

    private func refreshEnvironment(for session: Session) {
        let pid = session.engine.foregroundPid
        let env: ProjectEnvironment
        if session.shellEnvironment.isEmpty {
            env = EnvironmentDetector.detect(cwd: session.currentDirectory, pid: pid)
        } else {
            env = EnvironmentDetector.extract(
                shellEnv: session.shellEnvironment,
                cwd: session.currentDirectory,
                allowProjectFallback: false
            )
        }
        guard session.environment != env else { return }
        session.environment = env
    }

    /// Debounced persistence of the whole snapshot — every mutation site and
    /// the window controller's frame changes funnel here (the frame itself is
    /// read by `WindowPersistence.frameProvider` at write time). A torn-down
    /// store never re-arms: after a red-button close `removeWindow` has
    /// dropped the slot, and a late AppKit notification or a click on the
    /// still-visible dead window would otherwise upsert it back. ⌘Q's drain
    /// loses nothing to this — its post-drain `flushPersistence` is ungated
    /// and writes the snapshot captured before engine teardown.
    func scheduleSave() {
        guard !isTerminated else { return }
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDebounce)
            guard let self, !Task.isCancelled else { return }
            self.flushPersistence()
        }
    }

    private func snapshot() -> PersistedState {
        PersistedState(
            workspaces: workspaces.map(PersistedWorkspace.init),
            activeWorkspaceId: activeWorkspaceId,
            sidebarMode: sidebarMode,
            rightSidebarMode: rightSidebarMode,
            // Legacy readers do not know Chat (or, before F2, Team).
            sidebarContent: leftNavigation.legacySelectedContent == .files ? .files : .workspaces,
            sidebarSelectedContent: leftNavigation.legacySelectedContent.rawValue,
            chatSidebarPreferences: chatSidebarPreferences,
            rightSidebarContent: rightSidebarContent,
            sidebarWidth: Double(sidebarWidth),
            rightSidebarWidth: Double(rightSidebarWidth),
            collapsedInfoSections: collapsedInfoSections.isEmpty
                ? nil
                : collapsedInfoSections.sorted(),
            rightSidebarDefault115Applied: true,
            agentTabRepair119Applied: true,
            leftNavigation: leftNavigation
        )
    }

    private func startKiroConversationIfNeeded(for session: Session) {
        let key = session.displayAgent.rosterId
        guard key == AgentTemplate.kiro.id else { return }
        let path = AgentPadShellIntegration.kiroACPRecordPath(for: session.id)
        kiroConversationMonitor.start(sessionId: session.id, path: path) { [weak self, weak session] id in
            guard let self, let session else { return }
            self.applyConversationId(conversationId: id, sessionId: session.id)
        }
    }
}
