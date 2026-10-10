import Foundation
import AgentPadHookKit

/// On-disk shape of `WorkspaceStore`. Just the metadata — engine state
/// (scrollback, in-flight processes) can't survive PTY exit, so a restored
/// workspace re-spawns a fresh `LibghosttyEngine` per leaf and lands it in
/// the saved cwd via `TerminalSessionConfig.workingDirectory`.
struct PersistedState: Codable, Equatable {
    var workspaces: [PersistedWorkspace]
    var activeWorkspaceId: UUID?
    var sidebarMode: SidebarMode?
    var rightSidebarMode: SidebarMode?
    /// Optional so state.json files written before the file-tree toggle
    /// existed still decode (nil → `.workspaces`).
    var sidebarContent: SidebarContent?
    /// New modes are stored separately so a rollback still decodes the
    /// legacy sidebarContent enum and restores every workspace and tab.
    var sidebarSelectedContent: String?
    var chatSidebarPreferences: ChatSidebarPreferences?
    /// Optional so state.json files written before the History pane existed
    /// still decode (nil → `.agents`).
    var rightSidebarContent: RightSidebarContent?
    /// Optional so pre-resizable-sidebar state files decode (nil → the
    /// design width). Clamped on restore, not trusted from disk.
    var sidebarWidth: Double?
    /// Optional so pre-resizable-right-panel state files decode (nil → the
    /// design width). Clamped on restore, not trusted from disk.
    var rightSidebarWidth: Double?
    /// Session Info's collapsed section titles. Optional so state files
    /// written before the inspector existed decode (nil → nothing collapsed);
    /// stored sorted so the saved file is byte-stable across saves.
    var collapsedInfoSections: [String]?
    /// 1.1.5 hides the panel once for existing windows, then keeps their choice.
    /// Optional so older state files decode without resetting workspaces/tabs.
    var rightSidebarDefault115Applied: Bool?
    /// 1.1.9 could save agents as terminals while quitting. Repair each saved
    /// window once; later intentional agent exits must remain terminals.
    var agentTabRepair119Applied: Bool?
    var leftNavigation: LeftNavigationPreferences?
}

/// Root of the multi-window `state.json`. Each `PersistedWindow` is one
/// AgentPad window's `WorkspaceStore`; array order is window restore order.
struct PersistedApp: Codable, Equatable {
    var windows: [PersistedWindow]
    var formatVersion: Int? = 2
}

/// A window's frame in AppKit screen points (origin bottom-left). Restored
/// through `WindowPlacement` against the launch-time screen layout.
struct PersistedFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct PersistedWindow: Codable, Equatable {
    var id: UUID
    var state: PersistedState
    /// Absent in files written before v0.51.9 (nil → the window is placed
    /// the old way: centered / cascaded at the default size).
    var frame: PersistedFrame?

    init(id: UUID, state: PersistedState, frame: PersistedFrame? = nil) {
        self.id = id; self.state = state; self.frame = frame
    }
    private enum CodingKeys: String, CodingKey { case id, state, frame }
    init(from decoder: Decoder) throws {
        do {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            state = try c.decode(PersistedState.self, forKey: .state)
            frame = try c.decodeIfPresent(PersistedFrame.self, forKey: .frame)
        } catch {
            id = UUID(); state = Self.recoveryState(); frame = nil
        }
    }
    static func recoveryState() -> PersistedState {
        let id = UUID()
        var tab = PersistedTab(id: id, agentId: "terminal", currentDirectoryPath: homeDirectoryPath)
        tab.content = .tool(.unavailable(id))
        let pane = PersistedPane(id: UUID(), tabs: [tab], activeTabId: id)
        let workspace = PersistedWorkspace(id: UUID(), workingDirectoryPath: homeDirectoryPath,
            root: PersistedPaneNode(id: pane.id, kind: .pane(pane)))
        return PersistedState(workspaces: [workspace], activeWorkspaceId: workspace.id)
    }
}

struct PersistedWorkspace: Codable, Equatable {
    var id: UUID
    var workingDirectoryPath: String
    var root: PersistedPaneNode
    var activePaneId: UUID?
    var customTitle: String?
    /// nil = top-level workspace; non-nil = this is a git worktree whose
    /// source workspace persisted with this id. Decoded with
    /// `decodeIfPresent` so pre-worktree `state.json` files still load.
    var worktreeParentId: UUID?
    var worktreeBranch: String?
    /// Disk root captured at worktree-create time. Separate from
    /// `workingDirectoryPath` so the latter can drift with OSC 7 cwd
    /// reports without breaking close/reconcile path lookups.
    var worktreePath: String?
    /// SSH destination of an SSH workspace. Decoded as optional so state
    /// files written before the field restore as plain local workspaces.
    var sshRemoteHost: String?
    /// The workspace's tag. Exactly one of `tagPreset` (a `WorkspaceColorTag`
    /// raw value) and `tagCustomHex` is set, which keeps "the user picked this
    /// themselves" in the file rather than re-deriving it by comparing colours.
    /// Flat optionals rather than a nested object so a hand-edited or truncated
    /// `state.json` degrades one field at a time instead of failing the restore.
    var tagPreset: String?
    var tagCustomHex: String?
    var tagName: String?

    @MainActor
    init(_ ws: Workspace) {
        self.id = ws.id
        self.workingDirectoryPath = ws.workingDirectory.path
        self.root = PersistedPaneNode(ws.root)
        self.activePaneId = ws.activePaneId
        self.customTitle = ws.customTitle
        self.worktreeParentId = ws.worktreeParentId
        self.worktreeBranch = ws.worktreeBranch
        self.worktreePath = ws.worktreePath?.path
        self.sshRemoteHost = ws.sshRemoteHost
        self.tagPreset = ws.tag?.color.preset?.rawValue
        self.tagCustomHex = ws.tag?.color.customHex
        self.tagName = ws.tag?.name
    }

    init(id: UUID, workingDirectoryPath: String, root: PersistedPaneNode, activePaneId: UUID? = nil, customTitle: String? = nil, worktreeParentId: UUID? = nil, worktreeBranch: String? = nil, worktreePath: String? = nil, sshRemoteHost: String? = nil, tagPreset: String? = nil, tagCustomHex: String? = nil, tagName: String? = nil) {
        self.id = id
        self.workingDirectoryPath = workingDirectoryPath
        self.root = root
        self.activePaneId = activePaneId
        self.customTitle = customTitle
        self.worktreeParentId = worktreeParentId
        self.worktreeBranch = worktreeBranch
        self.worktreePath = worktreePath
        self.sshRemoteHost = sshRemoteHost
        self.tagPreset = tagPreset
        self.tagCustomHex = tagCustomHex
        self.tagName = tagName
    }

    private enum CodingKeys: String, CodingKey {
        case id, workingDirectoryPath, root, activePaneId, customTitle
        case worktreeParentId, worktreeBranch, worktreePath, sshRemoteHost, tagPreset, tagCustomHex, tagName
        // Legacy keys
        case tabs, activeTabId
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(workingDirectoryPath, forKey: .workingDirectoryPath)
        try c.encode(root, forKey: .root)
        try c.encodeIfPresent(activePaneId, forKey: .activePaneId)
        try c.encodeIfPresent(customTitle, forKey: .customTitle)
        try c.encodeIfPresent(worktreeParentId, forKey: .worktreeParentId)
        try c.encodeIfPresent(worktreeBranch, forKey: .worktreeBranch)
        try c.encodeIfPresent(worktreePath, forKey: .worktreePath)
        try c.encodeIfPresent(sshRemoteHost, forKey: .sshRemoteHost)
        try c.encodeIfPresent(tagPreset, forKey: .tagPreset)
        try c.encodeIfPresent(tagCustomHex, forKey: .tagCustomHex)
        try c.encodeIfPresent(tagName, forKey: .tagName)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        workingDirectoryPath = try c.decode(String.self, forKey: .workingDirectoryPath)
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        worktreeParentId = try c.decodeIfPresent(UUID.self, forKey: .worktreeParentId)
        worktreeBranch = try c.decodeIfPresent(String.self, forKey: .worktreeBranch)
        worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        sshRemoteHost = try c.decodeIfPresent(String.self, forKey: .sshRemoteHost)
        tagPreset = try c.decodeIfPresent(String.self, forKey: .tagPreset)
        tagCustomHex = try c.decodeIfPresent(String.self, forKey: .tagCustomHex)
        tagName = try c.decodeIfPresent(String.self, forKey: .tagName)
        if let root = try c.decodeIfPresent(PersistedPaneNode.self, forKey: .root) {
            self.root = root
            self.activePaneId = try c.decodeIfPresent(UUID.self, forKey: .activePaneId)
        } else {
            // Legacy schema: flat `tabs: [PersistedTab]`. Wrap into a single Pane.
            let legacy = try c.decode([PersistedTab].self, forKey: .tabs)
            let activeTabId = try c.decodeIfPresent(UUID.self, forKey: .activeTabId)
            let pane = PersistedPane(
                id: UUID(),
                tabs: legacy,
                activeTabId: activeTabId
            )
            self.root = PersistedPaneNode(id: pane.id, kind: .pane(pane))
            self.activePaneId = pane.id
        }
    }
}

struct PersistedPaneNode: Codable, Equatable {
    var id: UUID
    var kind: PersistedPaneKind
}

indirect enum PersistedPaneKind: Equatable {
    case pane(PersistedPane)
    case split(orientation: SplitOrientation, first: PersistedPaneNode, second: PersistedPaneNode, fraction: Double)
}

extension PersistedPaneNode {
    @MainActor
    init(_ node: PaneNode) {
        self.id = node.id
        switch node.content {
        case .pane(let pane):
            self.kind = .pane(PersistedPane(pane))
        case .split(let orientation, let first, let second, let fraction):
            self.kind = .split(
                orientation: orientation,
                first: PersistedPaneNode(first),
                second: PersistedPaneNode(second),
                fraction: fraction
            )
        }
    }
}

extension PersistedPaneKind: Codable {
    private enum CodingKeys: String, CodingKey { case pane, split }

    private struct SplitPayload: Codable, Equatable {
        var orientation: SplitOrientation
        var first: PersistedPaneNode
        var second: PersistedPaneNode
        var fraction: Double
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let p):
            try c.encode(p, forKey: .pane)
        case .split(let orient, let first, let second, let fraction):
            try c.encode(
                SplitPayload(orientation: orient, first: first, second: second, fraction: fraction),
                forKey: .split
            )
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let pane = try c.decodeIfPresent(PersistedPane.self, forKey: .pane) {
            self = .pane(pane)
        } else if let payload = try c.decodeIfPresent(SplitPayload.self, forKey: .split) {
            self = .split(
                orientation: payload.orientation,
                first: payload.first,
                second: payload.second,
                fraction: payload.fraction
            )
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .pane, in: c,
                debugDescription: "PersistedPaneKind requires either pane or split"
            )
        }
    }
}

struct PersistedPane: Codable, Equatable {
    var id: UUID
    var tabs: [PersistedTab]
    var activeTabId: UUID?

    @MainActor
    init(_ pane: Pane) {
        self.id = pane.id
        self.tabs = pane.tabs.map(PersistedTab.init)
        self.activeTabId = pane.activeTabId
    }

    init(id: UUID, tabs: [PersistedTab], activeTabId: UUID? = nil) {
        self.id = id
        self.tabs = tabs
        self.activeTabId = activeTabId
    }
}

struct PersistedTab: Codable, Equatable {
    var id: UUID
    var agentId: String
    var currentDirectoryPath: String
    var customTitle: String?
    /// Optional — only Claude reports it today. Decoded with
    /// `decodeIfPresent` so state.json files written by pre-resume AgentPad
    /// versions still load.
    var conversationId: String?
    var launchOrigin: AgentLaunchOrigin?
    var profileID: UUID?
    var profileOriginalCwd: URL?
    /// nil is legacy (inherit workspace host); empty explicitly means local.
    /// Moving a tab must not change where it reconnects on the next launch.
    var sshWorkspaceHost: String?
    // AgentPad: set for a channel tab; older files have none and read as terminals.
    var channel: ChannelRef?
    // AgentPad: a saved list persists its organization address and kind only.
    var inbox: ChatInboxRef?
    var content: TabContent?
    var navigation: TabNavigation?

    private enum CodingKeys: String, CodingKey {
        case id, agentId, currentDirectoryPath, customTitle, conversationId, launchOrigin, profileID, profileOriginalCwd, sshWorkspaceHost, channel, inbox, content, navigation
    }

    init(from decoder: Decoder) throws {
        // A malformed or newer tab is isolated; never reinterpret it as shell.
        do {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            if c.contains(.content) {
                content = try c.decode(TabContent.self, forKey: .content)
            } else {
                channel = try c.decodeIfPresent(ChannelRef.self, forKey: .channel)
                inbox = try c.decodeIfPresent(ChatInboxRef.self, forKey: .inbox)
            }
            agentId = try c.decode(String.self, forKey: .agentId)
            currentDirectoryPath = try c.decode(String.self, forKey: .currentDirectoryPath)
            customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
            conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId)
            launchOrigin = try c.decodeIfPresent(AgentLaunchOrigin.self, forKey: .launchOrigin)
            profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
            profileOriginalCwd = try c.decodeIfPresent(URL.self, forKey: .profileOriginalCwd)
            sshWorkspaceHost = try c.decodeIfPresent(String.self, forKey: .sshWorkspaceHost)
            navigation = try c.decodeIfPresent(TabNavigation.self, forKey: .navigation)
            if case .channel(let ref) = content { channel = ref }
            if case .chatInbox(let ref) = content { inbox = ref }
        } catch {
            id = UUID(); agentId = "terminal"; currentDirectoryPath = homeDirectoryPath
            content = .tool(.unavailable(id))
        }
    }

    @MainActor
    init(_ session: Session) {
        if let original = session.unavailableTab { self = original; return }
        self.id = session.id
        self.agentId = session.agent.id
        self.currentDirectoryPath = session.currentDirectory.path
        // AgentPad: a channel tab keeps no title — its name is its card's (DESIGN-F2).
        self.customTitle = session.hasProcess ? session.customTitle : nil
        self.conversationId = session.conversationId
        self.launchOrigin = session.launchOrigin
        self.profileID = session.profileID
        self.profileOriginalCwd = session.profileOriginalCwd
        self.sshWorkspaceHost = session.sshWorkspaceHost ?? ""
        self.channel = session.channel
        self.inbox = session.inbox
        self.content = session.content
        self.navigation = session.tabState?.navigation
    }

    init(id: UUID, agentId: String, currentDirectoryPath: String, customTitle: String? = nil, conversationId: String? = nil) {
        self.id = id
        self.agentId = agentId
        self.currentDirectoryPath = currentDirectoryPath
        self.customTitle = customTitle
        self.conversationId = conversationId
    }
}

@MainActor
protocol Persistence {
    func load() -> PersistedState?
    func save(_ state: PersistedState)
    func saveChecked(_ state: PersistedState) throws
}

extension Persistence {
    func saveChecked(_ state: PersistedState) throws { save(state) }
}

/// Owns the single `state.json` for the whole app. Holds every window's
/// `PersistedState` in memory (ordered) and writes the file synchronously
/// on each change. `WorkspaceStore`s never touch this directly — each gets
/// a `WindowPersistence` scoped to its own `windowId`.
@MainActor
final class AppPersistence {
    static var defaultFileURL: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["AGENTPAD_DEBUG_STATE_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent(AppIdentity.supportDirectoryName, isDirectory: true).appendingPathComponent("state-v2.json")
    }
    private let fileURL: URL
    private var windows: [PersistedWindow]
    private let writer: (Data, URL) throws -> Void
    private(set) var lastError: Error?
    private var unreadable = false
    let drafts: DraftRepository

    init(fileURL: URL = AppPersistence.defaultFileURL, legacyURL: URL? = nil,
         writer: @escaping (Data, URL) throws -> Void = { data, url in
             try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
             try data.write(to: url, options: .atomic)
         }) {
        self.fileURL = fileURL; self.writer = writer
        self.drafts = DraftRepository(fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("tab-drafts-v1.json"), write: writer)
        windows = []
        let legacy = legacyURL ?? (fileURL.lastPathComponent == "state-v2.json" ? fileURL.deletingLastPathComponent().appendingPathComponent("state.json") : nil)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do { windows = try Self.read(fileURL) }
            catch { lastError = error; unreadable = true; windows = [Self.unavailableWindow()] }
        } else if let legacy, FileManager.default.fileExists(atPath: legacy.path) {
            do {
                windows = try Self.read(legacy)
                try write(windows) // Original is retained for a 1.1.8 rollback.
            } catch { lastError = error; unreadable = true; windows = [Self.unavailableWindow()] }
        }
        do { try backUpUnreadableFile() }
        catch { lastError = error }
    }
    var windowIds: [UUID] { windows.map(\.id) }
    func state(for id: UUID) -> PersistedState? { windows.first { $0.id == id }?.state }
    func frame(for id: UUID) -> PersistedFrame? { windows.first { $0.id == id }?.frame }

    @discardableResult
    func setWindow(_ id: UUID, state: PersistedState, frame: PersistedFrame? = nil) -> Result<Void, Error> {
        setWindows([PersistedWindow(id: id, state: state, frame: frame)])
    }
    /// One atomic write for both ends of a transfer; memory commits only on success.
    @discardableResult
    func setWindows(_ updates: [PersistedWindow]) -> Result<Void, Error> {
        var next = windows
        for update in updates {
            if let i = next.firstIndex(where: { $0.id == update.id }) {
                let frame = update.frame ?? next[i].frame
                next[i] = update; next[i].frame = frame
            } else { next.append(update) }
        }
        return commit(next)
    }
    @discardableResult
    func removeWindow(_ id: UUID) -> Result<Void, Error> { commit(windows.filter { $0.id != id }) }
    private func commit(_ next: [PersistedWindow]) -> Result<Void, Error> {
        do {
            try backUpUnreadableFile()
            try write(next); windows = next; lastError = nil
            return .success(())
        } catch { lastError = error; return .failure(error) }
    }
    private func write(_ next: [PersistedWindow]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writer(encoder.encode(PersistedApp(windows: next)), fileURL)
    }
    private func backUpUnreadableFile() throws {
        guard unreadable else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let backup = fileURL.appendingPathExtension("corrupt-\(Date().timeIntervalSince1970)")
            try FileManager.default.copyItem(at: fileURL, to: backup)
        }
        // If backup failed, the next save retries it instead of blocking forever.
        // A failed legacy import already has its original in state.json.
        unreadable = false
    }
    private static func read(_ url: URL) throws -> [PersistedWindow] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        if let app = try? decoder.decode(PersistedApp.self, from: data) {
            guard app.formatVersion == nil || app.formatVersion == 2 else { throw CocoaError(.fileReadCorruptFile) }
            return app.windows
        }
        return [PersistedWindow(id: UUID(), state: try decoder.decode(PersistedState.self, from: data))]
    }
    static func loadFromDisk(from url: URL) -> [PersistedWindow] { (try? read(url)) ?? [] }
    private static func unavailableWindow() -> PersistedWindow {
        PersistedWindow(id: UUID(), state: PersistedWindow.recoveryState())
    }
}

/// A `Persistence` scoped to one window's slice of the shared `state.json`.
/// `WorkspaceStore` uses it like any `Persistence` and never knows it's one
/// window among several. A class, not a struct: `frameProvider` is wired
/// AFTER the store (which owns this object) and the window controller (which
/// owns the frame) both exist — a struct copy inside the store would never
/// see it.
@MainActor
final class WindowPersistence: Persistence {
    let windowId: UUID
    let app: AppPersistence
    /// Read at every save so the window's frame rides the same debounced
    /// write as the workspace state. Set by `AppDelegate.addWindow`.
    var frameProvider: (() -> PersistedFrame?)?

    init(windowId: UUID, app: AppPersistence) {
        self.windowId = windowId
        self.app = app
    }

    func load() -> PersistedState? { app.state(for: windowId) }
    func save(_ state: PersistedState) { app.setWindow(windowId, state: state, frame: frameProvider?()) }
    func saveChecked(_ state: PersistedState) throws {
        try app.setWindow(windowId, state: state, frame: frameProvider?()).get()
    }
}
