import Foundation

/// Addresses contain identifiers, never display names or authorization.
struct OrgKey: Codable, Hashable, Sendable {
    let server: ChatServerAddress
    let accountID: String
    let orgID: String

    init(server: String, accountID: String, orgID: String) throws {
        self.server = try ChatServerAddress(parsing: server)
        self.accountID = accountID
        self.orgID = orgID
    }
    init(_ key: ChatOrgKey) {
        server = key.server; accountID = key.accountId; orgID = key.orgId
    }
}

enum TeamScope: Codable, Hashable, Sendable { case local, server(OrgKey) }

enum SettingsTabSection: String, CaseIterable, Codable, Sendable {
    case general, appearance, agents, terminals, openIn, statusBar, notifications, advanced, about, updates
    var title: String {
        switch self {
        case .openIn: "Open in"
        case .statusBar: "Status Bar"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

/// Sections, revisions and scrolling deliberately do not participate in identity.
/// Later migration groups add their views, not a second routing system.
enum ToolRoute: Codable, Hashable, Sendable {
    case settings
    case notifications
    case allSessions
    case directMessage(ChatDMRef)
    case directMessageDraft(OrgKey, peer: String)
    case newDM(OrgKey)
    case linkFailure
    case organization(OrgKey)
    case agent(OrgKey, agentID: String)
    case ask(OrgKey, agentID: String)
    case request(TeamScope, requestID: String)
    case publishedAgents(TeamScope)
    case teamActivity(TeamScope)
    case publication(TeamScope, publicationID: String)
    case publish(TeamScope, draftID: UUID, sourceSessionID: UUID?, conversationID: String?)
    case forward(sourceSessionID: UUID, answerSnapshotID: UUID)
    case connection
    case newChannel(OrgKey, teamID: String, draftID: UUID)
    case newSSH(draftID: UUID)
    case newWorktree(repository: String, sourceWorkspaceID: UUID, draftID: UUID)
    case workspaceDetails(UUID)
    case files(canonicalPath: String)
    case closeWorkspaces(intentID: UUID)
    case fileOperations(operationID: UUID)
    case importSession(agentID: String, conversationID: String, externalSourceID: String)
    case viewer(OrgKey, channelID: String, messageID: String, attachmentID: String)
    case unavailable(UUID)

    var isWindowScoped: Bool {
        switch self { case .settings, .notifications, .allSessions, .linkFailure: true; default: false }
    }
    func key(windowID: UUID) -> TabKey {
        // Source metadata is pinned on the route but is not a second identity.
        let identity: ToolRoute
        switch self {
        case let .publish(scope, id, _, _): identity = .publish(scope, draftID: id, sourceSessionID: nil, conversationID: nil)
        case let .newChannel(scope, _, id): identity = .newChannel(scope, teamID: "", draftID: id)
        case let .newWorktree(_, _, id): identity = .newWorktree(repository: "", sourceWorkspaceID: id, draftID: id)
        case let .files(path): identity = .files(canonicalPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path)
        default: identity = self
        }
        return TabKey(route: identity, windowID: isWindowScoped ? windowID : nil)
    }
    var title: String {
        switch self {
        case .settings: "Settings"
        case .notifications: "Notifications"
        case .allSessions: "All sessions"
        case .directMessage, .directMessageDraft: "Direct message"
        case .newDM: "New message"
        case .linkFailure: "Link could not be opened"
        case .organization: "Organization"
        case .agent: "Agent"
        case .ask: "Ask agent"
        case .request: "Request"
        case .publishedAgents: "Published Agents"
        case .teamActivity: "Team activity"
        case .publication: "Publication"
        case .publish: "Publish"
        case .forward: "Forward"
        case .connection: "Connection"
        case .newChannel: "New channel"
        case .newSSH: "New SSH workspace"
        case .newWorktree: "New worktree"
        case .workspaceDetails: "Workspace details"
        case .files: "Files"
        case .closeWorkspaces: "Close workspaces"
        case .fileOperations: "File operations"
        case .importSession: "Import session"
        case .viewer: "Viewer"
        case .unavailable: "Unavailable tab"
        }
    }
    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .notifications: "bell"
        case .allSessions: "clock"
        case .linkFailure, .unavailable: "exclamationmark.triangle"
        default: "rectangle.on.rectangle"
        }
    }
}

struct TabKey: Hashable, Sendable { let route: ToolRoute; let windowID: UUID? }
typealias TabID = UUID

enum TabContent: Codable, Equatable {
    case terminal
    case channel(ChannelRef)
    case chatInbox(ChatInboxRef)
    case tool(ToolRoute)

    var hasProcess: Bool { if case .terminal = self { true } else { false } }
}

/// Only this allowlist crosses the UI persistence boundary.
struct TabNavigation: Codable, Equatable {
    var settingsSection: SettingsTabSection = .general
    var anchor: String?
    var selection: String?
    var zoom: Double = 1
    var fileTransfer: FileTransferSnapshot?
    var draftID: UUID?
    var settingsScrollOffsets: [String: Double]?
    var allSessions: AllSessionsFilterState?
}

@MainActor @Observable
final class TabState {
    var route: ToolRoute
    var navigation: TabNavigation
    var draft: TabDraft?
    var saveError: String?
    var savedRevision: Int?
    /// OTP, clipboard, signed URLs and authorization live here only.
    var transient: [String: String] = [:]
    var message: String?
    var revision = 0
    var isClosed = false
    let confirmation = ConfirmationCoordinator()
    @ObservationIgnored var changed: () -> Void = {}
    @ObservationIgnored var persistEdits: (() throws -> Void)?
    @ObservationIgnored var discardEdits: (() -> Void)?
    @ObservationIgnored var canShowConfirmation: () -> Bool = { true }
    let settingsScreen = SettingsScreenState()
    var allSessionsModel: AllSessionsModel?
    var dmPendingThread: String?
    var dmModel: ChatDMModel?
    var dmPeerModel: ChatDMPeerModel?
    var newDMModel: ChatDMNewModel?
    var localForm: LocalFormState?
    var organizationForm: OrganizationFormState?
    var publicationForm: PublicationFormState?
    var requestForm: RequestTabModel?
    var files: FileTreeModel?
    var fileOperation: FileTransferBatch?
    var closeWorkspaces: CloseWorkspaceBatch?
    var importSession: ImportSessionModel?
    var connectionForm: ChatConnectModel?
    var askForm: PersonalAskModel?
    var newChannelForm: NewChannelModel?
    var forwardForm: AgentAnswerForward?
    var viewerForm: AttachmentViewerModel?

    init(route: ToolRoute, navigation: TabNavigation = TabNavigation()) {
        self.route = route; self.navigation = navigation
    }
    func select(_ section: SettingsTabSection) {
        guard navigation.settingsSection != section else { return }
        confirmation.invalidate()
        navigation.settingsSection = section
        revision += 1
        changed()
    }
    func edit(_ payload: TabDraft.Payload) {
        let next = (draft?.revision ?? 0) + 1
        let id = draft?.id ?? navigation.draftID ?? UUID()
        draft = TabDraft(id: id, revision: next, route: route, payload: payload)
        navigation.draftID = id
        revision += 1
        changed()
    }
    /// Async picker/load results must belong to the same live revision.
    func accept(revision expected: Int, _ update: () -> Void) -> Bool {
        guard !isClosed, revision == expected else { return false }
        update(); return true
    }
    func leave(moving: Bool = false) {
        confirmation.invalidate(); fileOperation?.stopIfWaiting(); revision += 1
        // A move keeps the live form. Closing or hiding it forgets login
        // input even when the last window and its TabState remain alive.
        if !moving { connectionForm?.close(); connectionForm = nil }
    }
    func close() { dmPeerModel?.stop(); dmPeerModel = nil; dmModel?.stop(); dmModel = nil; newDMModel?.stop(); newDMModel = nil; allSessionsModel?.stop(); allSessionsModel = nil; leave(); files?.cancel(); viewerForm?.invalidate(); transient.removeAll(); isClosed = true }
}
