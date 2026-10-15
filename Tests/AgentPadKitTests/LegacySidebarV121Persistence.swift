// Frozen 1.2.1 persistence codecs copied from 96dc29b: Sessions/Persistence.swift
// and AgentPad/Chat/ChatSidebarModel.swift. Only type names are prefixed and
// runtime-to-storage convenience initializers are omitted. In particular, keep
// the synthesized required `collapsed` field and whole-window recovery path.
// Route and UI value types are unchanged from that release.
import Foundation
import AgentPadHookKit
@testable import AgentPadKit

/// On-disk shape of `WorkspaceStore`. Just the metadata — engine state
/// (scrollback, in-flight processes) can't survive PTY exit, so a restored
/// workspace re-spawns a fresh `LibghosttyEngine` per leaf and lands it in
/// the saved cwd via `TerminalSessionConfig.workingDirectory`.
struct LegacySidebarV121PersistedState: Codable, Equatable {
    var workspaces: [LegacySidebarV121PersistedWorkspace]
    var activeWorkspaceId: UUID?
    var sidebarMode: SidebarMode?
    var rightSidebarMode: SidebarMode?
    /// Optional so state.json files written before the file-tree toggle
    /// existed still decode (nil → `.workspaces`).
    var sidebarContent: SidebarContent?
    /// New modes are stored separately so a rollback still decodes the
    /// legacy sidebarContent enum and restores every workspace and tab.
    var sidebarSelectedContent: String?
    var chatSidebarPreferences: LegacySidebarV121ChatSidebarPreferences?
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

/// Root of the multi-window `state.json`. Each `LegacySidebarV121PersistedWindow` is one
/// AgentPad window's `WorkspaceStore`; array order is window restore order.
struct LegacySidebarV121PersistedApp: Codable, Equatable {
    var windows: [LegacySidebarV121PersistedWindow]
    var formatVersion: Int? = 2
}

/// A window's frame in AppKit screen points (origin bottom-left). Restored
/// through `WindowPlacement` against the launch-time screen layout.
struct LegacySidebarV121PersistedFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct LegacySidebarV121PersistedWindow: Codable, Equatable {
    var id: UUID
    var state: LegacySidebarV121PersistedState
    /// Absent in files written before v0.51.9 (nil → the window is placed
    /// the old way: centered / cascaded at the default size).
    var frame: LegacySidebarV121PersistedFrame?

    init(id: UUID, state: LegacySidebarV121PersistedState, frame: LegacySidebarV121PersistedFrame? = nil) {
        self.id = id; self.state = state; self.frame = frame
    }
    private enum CodingKeys: String, CodingKey { case id, state, frame }
    init(from decoder: Decoder) throws {
        do {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            state = try c.decode(LegacySidebarV121PersistedState.self, forKey: .state)
            frame = try c.decodeIfPresent(LegacySidebarV121PersistedFrame.self, forKey: .frame)
        } catch {
            id = UUID(); state = Self.recoveryState(); frame = nil
        }
    }
    static func recoveryState() -> LegacySidebarV121PersistedState {
        let id = UUID()
        var tab = LegacySidebarV121PersistedTab(id: id, agentId: "terminal", currentDirectoryPath: homeDirectoryPath)
        tab.content = .tool(.unavailable(id))
        let pane = LegacySidebarV121PersistedPane(id: UUID(), tabs: [tab], activeTabId: id)
        let workspace = LegacySidebarV121PersistedWorkspace(id: UUID(), workingDirectoryPath: homeDirectoryPath,
            root: LegacySidebarV121PersistedPaneNode(id: pane.id, kind: .pane(pane)))
        return LegacySidebarV121PersistedState(workspaces: [workspace], activeWorkspaceId: workspace.id)
    }
}

struct LegacySidebarV121PersistedWorkspace: Codable, Equatable {
    var id: UUID
    var workingDirectoryPath: String
    var root: LegacySidebarV121PersistedPaneNode
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



    init(id: UUID, workingDirectoryPath: String, root: LegacySidebarV121PersistedPaneNode, activePaneId: UUID? = nil, customTitle: String? = nil, worktreeParentId: UUID? = nil, worktreeBranch: String? = nil, worktreePath: String? = nil, sshRemoteHost: String? = nil, tagPreset: String? = nil, tagCustomHex: String? = nil, tagName: String? = nil) {
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
        if let root = try c.decodeIfPresent(LegacySidebarV121PersistedPaneNode.self, forKey: .root) {
            self.root = root
            self.activePaneId = try c.decodeIfPresent(UUID.self, forKey: .activePaneId)
        } else {
            // Legacy schema: flat `tabs: [LegacySidebarV121PersistedTab]`. Wrap into a single Pane.
            let legacy = try c.decode([LegacySidebarV121PersistedTab].self, forKey: .tabs)
            let activeTabId = try c.decodeIfPresent(UUID.self, forKey: .activeTabId)
            let pane = LegacySidebarV121PersistedPane(
                id: UUID(),
                tabs: legacy,
                activeTabId: activeTabId
            )
            self.root = LegacySidebarV121PersistedPaneNode(id: pane.id, kind: .pane(pane))
            self.activePaneId = pane.id
        }
    }
}

struct LegacySidebarV121PersistedPaneNode: Codable, Equatable {
    var id: UUID
    var kind: LegacySidebarV121PersistedPaneKind
}

indirect enum LegacySidebarV121PersistedPaneKind: Equatable {
    case pane(LegacySidebarV121PersistedPane)
    case split(orientation: SplitOrientation, first: LegacySidebarV121PersistedPaneNode, second: LegacySidebarV121PersistedPaneNode, fraction: Double)
}



extension LegacySidebarV121PersistedPaneKind: Codable {
    private enum CodingKeys: String, CodingKey { case pane, split }

    private struct SplitPayload: Codable, Equatable {
        var orientation: SplitOrientation
        var first: LegacySidebarV121PersistedPaneNode
        var second: LegacySidebarV121PersistedPaneNode
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
        if let pane = try c.decodeIfPresent(LegacySidebarV121PersistedPane.self, forKey: .pane) {
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
                debugDescription: "LegacySidebarV121PersistedPaneKind requires either pane or split"
            )
        }
    }
}

struct LegacySidebarV121PersistedPane: Codable, Equatable {
    var id: UUID
    var tabs: [LegacySidebarV121PersistedTab]
    var activeTabId: UUID?



    init(id: UUID, tabs: [LegacySidebarV121PersistedTab], activeTabId: UUID? = nil) {
        self.id = id
        self.tabs = tabs
        self.activeTabId = activeTabId
    }
}

struct LegacySidebarV121PersistedTab: Codable, Equatable {
    var id: UUID
    var agentId: String
    var currentDirectoryPath: String
    /// The explicit name lives only in SessionNames. Legacy customTitle has
    /// unknown provenance and is deliberately neither decoded nor migrated.
    var explicitNameKey: SessionNameKey?
    var lastDisplayTitle: SessionDisplayTitle?
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
        case id, agentId, currentDirectoryPath, explicitNameKey, lastDisplayTitle, conversationId, launchOrigin, profileID, profileOriginalCwd, sshWorkspaceHost, channel, inbox, content, navigation
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
            explicitNameKey = try c.decodeIfPresent(SessionNameKey.self, forKey: .explicitNameKey)
            lastDisplayTitle = try c.decodeIfPresent(SessionDisplayTitle.self, forKey: .lastDisplayTitle)
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



    init(id: UUID, agentId: String, currentDirectoryPath: String, explicitNameKey: SessionNameKey? = nil, conversationId: String? = nil) {
        self.id = id
        self.agentId = agentId
        self.currentDirectoryPath = currentDirectoryPath
        self.explicitNameKey = explicitNameKey
        self.conversationId = conversationId
    }
}


/// Only IDs and layout preferences go into window persistence. Names and
/// search results are always projected again through the F2 gate.
struct LegacySidebarV121ChatSidebarPreferences: Codable, Equatable {
    struct Section: Codable, Equatable, Hashable {
        var server, account, org: String
        var team: String?

        init(_ key: ChatOrgKey, team: String?) {
            server = key.server.description; account = key.accountId; org = key.orgId; self.team = team
        }
    }

    var attentionCollapsed: Bool?
    var width: Double = 268
    var collapsed: [Section] = []

    static func clampWidth(_ width: Double) -> Double {
        width.isFinite ? min(320, max(220, width)).rounded() : 268
    }

    mutating func setCollapsed(_ section: Section, _ value: Bool) {
        collapsed.removeAll { $0 == section }
        if value { collapsed.append(section) }
    }
}
