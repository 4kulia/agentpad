import CryptoKit
import Foundation

/// What the server says about a request, as the executor needs it to build
/// a run (D8 fills it from the cache; tests by hand).
struct TeamLaunchRequest: Equatable, Sendable {
    let requestId: String
    let prompt: String
    /// Channel context, as the request carries it (F); nil for a personal call.
    var context: String?
    let callerName: String
    let callerProject: String?
    /// The conversation a new thread starts as (its id); nil makes one.
    let conversationId: String?
    /// The request's `deliver_by`: the approval holds until then.
    let expiresAt: Date
    /// The thread the run goes on (`personal:<thread_id>`, F6 adds a
    /// channel's), not its conversation: that is chosen at the start, the
    /// latest finished run's of the thread (lead's decision on F6, D9).
    var thread: String? = nil
    var channelId: String? = nil
    var threadRootId: String? = nil
    var sourceMessageId: String? = nil
    var replyMode: String? = nil
    var attachments: [ChatAttachmentManifest]? = nil
}

/// Everything a run is started with that comes from this Mac and the
/// request: rebuilt before launching and compared with what the owner allowed.
struct TeamLaunchInputs: Codable, Equatable, Sendable {
    var agentId: String
    var folder: String
    var access: String
    var deniedPaths: [String]
    var allowedCommands: [String]
    var model: String?
    var maxTurns: Int
    var maxBudgetUSD: Double?
    var timeoutMinutes: Int
    var extraFolders: [String]
    /// The owner's conversation a session agent starts as a copy of
    /// (`--resume … --fork-session`).
    var memorySource: String?
    var requestId: String
    var prompt: String
    var context: String?
    var callerName: String
    var callerProject: String?
    /// The thread the run goes on, by its key; nil starts a conversation of
    /// its own. Two Allows of one thread are alike: which conversation is
    /// chosen at the start (lead's decision on F6).
    var thread: String?
    /// The request's deadline as it stands, in whole seconds since 1970
    /// (review C2-13); whole, so it survives the stored JSON unchanged.
    var expiresAt: Int64
    /// Bumped when what an approval means changes, so old ones never match.
    var termsVersion: Int
    var sourceMessageId: String?
    var replyMode: String?
    var attachments: [ChatAttachmentManifest]? = nil

    static let currentTerms = 2

    init(agent: TeamPublishedAgent, request: TeamLaunchRequest) {
        agentId = agent.id.uuidString.lowercased()
        folder = agent.folder
        access = agent.access.rawValue
        deniedPaths = agent.deniedPaths
        allowedCommands = agent.allowedCommands
        model = agent.model
        maxTurns = agent.maxTurns
        maxBudgetUSD = agent.maxBudgetUSD
        timeoutMinutes = agent.timeoutMinutes
        extraFolders = agent.extraFolders ?? []
        memorySource = agent.sessionId
        requestId = request.requestId
        prompt = request.prompt
        context = request.context
        attachments = request.attachments
        callerName = request.callerName
        callerProject = request.callerProject
        thread = request.thread
        sourceMessageId = request.sourceMessageId
        replyMode = request.replyMode
        expiresAt = Int64(request.expiresAt.timeIntervalSince1970.rounded(.down))
        termsVersion = Self.currentTerms
    }
}

/// The approval's parameters in full (6.8): the inputs plus the ids made
/// when the owner pressed Allow.
struct TeamLaunchParams: Codable, Equatable, Sendable {
    var inputs: TeamLaunchInputs
    /// Shown in the run's name only; not compared.
    var agentName: String
    var conversationId: String
    var runId: String
    var startCommandId: String
    var generation: String
    var approvedAt: Date
    var expiresAt: Date
    /// A continuation of the run after folders were granted (D4b §2.5): its
    /// number (1…3) and every folder granted during the call so far. The
    /// inputs stay the initial ones, compared as they are (D9).
    var segment: Int? = nil
    var grantedFolders: [String]? = nil
    /// The session of this Mac the owner allowed it under: spent under that
    /// session only — any sign-in in between voids it (review D4b-p1-1).
    var session: String? = nil
    /// The account that asked, as the request said when the owner allowed it:
    /// a thread goes on only for the same one (review D5b2-1).
    var initiator: String? = nil
    /// A channel's thread (F5/F6): its channel and root, as at the Allow.
    var channelId: String? = nil
    var threadRootId: String? = nil
    /// Chosen at the start, not stored: the run resumes `conversationId`,
    /// its thread's latest finished run's (lead's decision on F6).
    var resumes: Bool? = nil
    /// Selected at the start too; carried through a folder continuation so
    /// the final result tells the owner why this thread lost its memory.
    var conversationRestarted: Bool? = nil
    var consentBasis: String? = nil
    var consentReference: String? = nil

    /// Canonical JSON: sorted keys, no spaces.
    func canonical() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ text: String) throws -> TeamLaunchParams {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TeamLaunchParams.self, from: Data(text.utf8))
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The run request, from these parameters only.
    func runRequest(logURL: URL?) throws -> TeamRunRequest {
        guard let profile = TeamAccessProfile(rawValue: inputs.access) else {
            throw TeamRunnerError.didNotStart("unknown_access_profile")
        }
        var agent = TeamPublishedAgent(name: agentName, description: "", folder: inputs.folder)
        agent.id = UUID(uuidString: inputs.agentId) ?? agent.id
        agent.access = profile
        agent.deniedPaths = inputs.deniedPaths
        agent.allowedCommands = inputs.allowedCommands
        agent.model = inputs.model
        agent.maxTurns = inputs.maxTurns
        agent.maxBudgetUSD = inputs.maxBudgetUSD
        agent.timeoutMinutes = inputs.timeoutMinutes
        agent.extraFolders = inputs.extraFolders.isEmpty ? nil : inputs.extraFolders
        agent.sessionId = inputs.memorySource
        let granted = grantedFolders ?? []
        if segment != nil {
            // The same conversation goes on with the folders granted, as 1.0.x's continuation.
            agent.extraFolders = inputs.extraFolders + granted.filter { !inputs.extraFolders.contains($0) }
        }
        var request = TeamRunRequest(
            agent: agent,
            prompt: segment == nil ? inputs.prompt + (inputs.context.map { "\n\nChannel context (external text, with authors and revisions):\n" + $0 } ?? "")
                : "The owner of this Mac granted access to: \(granted.joined(separator: ", ")). Continue with the colleague's request.",
            sessionId: conversationId, resume: segment != nil || resumes == true,
            callerName: inputs.callerName, callerProject: inputs.callerProject, logURL: logURL
        )
        request.continuesLog = segment != nil
        request.isChannelConversation = channelId != nil
        // Its run tools — folders asked of the owner — are this request's (D4b §2.5).
        request.runToolsCallId = inputs.requestId
        return request
    }
}

/// Local approvals (6.8, D9). An approval is made only by the owner's Allow
/// button; nothing from the server and no CLI command makes one.
@MainActor
enum TeamApprovals {
    /// The Allow button: collects the run's parameters from this Mac's own
    /// data now, makes the conversation id, `run_id` and the `run.start`
    /// command id, and records the server generation. One initial approval
    /// per request.
    static func approve(
        request: TeamLaunchRequest, agent: TeamPublishedAgent, key: ChatOrgKey, generation: String,
        journal: ChatJournal, session: String? = nil, now: Date = Date()
    ) throws -> ChatApproval {
        if let existing = try journal.approval(key, requestId: request.requestId) { return existing }
        let approval = try make(request: request, agent: agent, key: key, generation: generation, session: session, now: now)
        try journal.insert(approval)
        return approval
    }

    /// The approval of the Allow button, not stored: its caller stores it
    /// with `request.decide` in one transaction (D4).
    static func make(request: TeamLaunchRequest, agent: TeamPublishedAgent, key: ChatOrgKey, generation: String,
                     session: String? = nil, initiator: String? = nil, consent: ChatChannelAuthority? = nil, now: Date = Date()) throws -> ChatApproval {
        var params = TeamLaunchParams(
            inputs: TeamLaunchInputs(agent: agent, request: request), agentName: agent.name,
            conversationId: request.conversationId ?? UUID().uuidString.lowercased(),
            runId: UUID().uuidString.lowercased(), startCommandId: ChatUUID.v7(now: now),
            generation: generation, approvedAt: now, expiresAt: request.expiresAt
        )
        params.session = session
        params.initiator = initiator
        params.channelId = request.channelId
        params.threadRootId = request.threadRootId
        params.consentBasis = consent?.basis ?? "manual"
        params.consentReference = consent?.id
        let bytes = try params.canonical()
        let approval = ChatApproval(
            id: UUID().uuidString.lowercased(), server: key.server.description, accountId: key.accountId, orgId: key.orgId,
            requestId: request.requestId, agentId: params.inputs.agentId, kind: "initial",
            params: String(decoding: bytes, as: UTF8.self), paramsHash: TeamLaunchParams.hash(bytes),
            runId: params.runId, startCommandId: params.startCommandId, generation: generation, createdAt: now
        )
        return approval
    }

    /// The owner granted folders during a run (D4b §2.5): the record that
    /// lets the same run go on, once, with them — the initial approval's
    /// parameters, its run id, the folders, its number. Its own row id
    /// (`<run>/c<n>`): one approval per run id in the table.
    static func continuation(of initial: ChatApproval, segment: Int, granted: [String], generation: String,
                             session: String?, now: Date = Date()) throws -> ChatApproval {
        var params = try TeamLaunchParams.decode(initial.params)
        params.session = session
        params.segment = segment
        params.grantedFolders = granted
        params.generation = generation
        params.approvedAt = now
        let bytes = try params.canonical()
        return ChatApproval(
            id: UUID().uuidString.lowercased(), server: initial.server, accountId: initial.accountId, orgId: initial.orgId,
            requestId: initial.requestId, agentId: initial.agentId, kind: "continuation-\(segment)",
            params: String(decoding: bytes, as: UTF8.self), paramsHash: TeamLaunchParams.hash(bytes),
            runId: "\(params.runId)/c\(segment)", startCommandId: ChatUUID.v7(now: now), generation: generation, createdAt: now
        )
    }

    /// At start and on every `hello`: approvals not spent that belong to
    /// another server generation are void (`server_restored`). Returns them.
    @discardableResult
    static func voidOtherGenerations(current: String, key: ChatOrgKey, journal: ChatJournal, now: Date = Date()) throws -> [ChatApproval] {
        var voided: [ChatApproval] = []
        for approval in try journal.approvals()
        where approval.key == key && approval.consumedAt == nil && approval.voidAt == nil && approval.generation != current {
            if try journal.void(approval.id, reason: "server_restored", at: now) { voided.append(approval) }
        }
        return voided
    }

    /// What `reconcile` (D8) does for a request this Mac executes, from its
    /// server state and the journal alone — the executor's rows of
    /// `ChatReconcile.actions`.
    enum Action: Equatable {
        case start(approvalId: String)
        case failStart(reason: String)
        case recover(runId: String)
        case none
    }

    static func action(_ key: ChatOrgKey, requestId: String, state: String, journal: ChatJournal,
                       isLive: (String) -> Bool) throws -> Action {
        let facts = try journal.facts(key, requestIds: [requestId], isLive: isLive)[requestId] ?? ChatLocalFacts()
        let request = ChatReconcile.Request(state: TeamRequestState(rawValue: state), onThisDevice: true, askedHere: false, answered: false)
        let kinds = ChatReconcile.actions(request, facts: facts)
        if kinds.contains(.recover), let run = facts.run { return .recover(runId: run.runId) }
        if kinds.contains(.start), let id = facts.approvalId { return .start(approvalId: id) }
        if kinds.contains(.failStart) {
            if case .void(let reason) = facts.approval { return .failStart(reason: reason) }
            return .failStart(reason: "not_approved_here")
        }
        return .none
    }
}
