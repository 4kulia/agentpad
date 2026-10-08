import AppKit
import GRDB
import Observation

struct ForwardDraft: Codable, Equatable {
    var snapshot: String
    var markdown: String
    var sourceTitle = "Saved answer"
    var conversationID: String? = nil
    var destination: OrgKey?
    var channelID = ""
    var threadID = ""
    var attemptID: UUID? = nil
    var attemptAuthor: Author? = nil
    var attemptSessionAuthor: ChatSessionAuthor? = nil
    enum Author: String, Codable { case session, account }
}

@MainActor
@Observable
final class AgentAnswerForward {
    struct Destination: Identifiable, Equatable { var id: String; var title: String }
    let caller: ChatLocalCaller?
    let sourceTitle: String
    let snapshot: String
    let conversationID: String?
    private(set) var destination: OrgKey?
    let service: ChatService
    private(set) var connection: ChatConnection?
    var text: String { didSet { edited() } }
    var organization = ""
    var channel = "" { didSet { edited() } }
    var thread = "" { didSet { edited() } }
    var channels: [Destination] = []
    var threads: [Destination] = []
    var moreChannels: String?
    var moreThreads: Int?
    var loadingChannels = false
    var loadingThreads = false
    var loading: Bool { loadingChannels || loadingThreads }
    var sending = false
    var submitted: Bool { attemptID != nil }
    var status: String?
    var problem: String?
    var active = true
    @ObservationIgnored var sourceIsCurrent: @MainActor () -> Bool
    @ObservationIgnored private var channelRevision = 0
    @ObservationIgnored private var threadRevision = 0
    private(set) var attemptID: UUID?
    private(set) var attemptAuthor: ForwardDraft.Author?
    private(set) var attemptSessionAuthor: ChatSessionAuthor?
    var restartConfirmation = ConfirmationCoordinator()
    var tabID = UUID()
    private var editRevision = 0
    @ObservationIgnored var changed: () -> Void = {}
    @ObservationIgnored var persist: () throws -> Void = {}
    @ObservationIgnored var isOpen: () -> Bool = { true }
    @ObservationIgnored private var initialDestinationsLoaded = false

    var draft: ForwardDraft {
        .init(snapshot: snapshot, markdown: text, sourceTitle: sourceTitle, conversationID: conversationID,
            destination: destination, channelID: channel, threadID: thread, attemptID: attemptID, attemptAuthor: attemptAuthor,
            attemptSessionAuthor: attemptSessionAuthor)
    }
    private func edited() { editRevision += 1; changed() }

    init(text: String, caller: ChatLocalCaller, sourceTitle: String, service: ChatService,
         sourceIsCurrent: @escaping @MainActor () -> Bool) {
        self.text = text; self.caller = caller; self.sourceTitle = sourceTitle; self.service = service
        self.connection = service.connection; self.sourceIsCurrent = sourceIsCurrent
        snapshot = text; conversationID = nil; destination = service.connection?.orgKey.map(OrgKey.init)
        organization = service.connection?.orgId ?? ""
    }

    init(draft: ForwardDraft, caller: ChatLocalCaller?, service: ChatService,
         sourceIsCurrent: @escaping @MainActor () -> Bool) {
        text = draft.markdown; snapshot = draft.snapshot; sourceTitle = draft.sourceTitle; conversationID = draft.conversationID
        destination = draft.destination; self.caller = caller; self.service = service; self.sourceIsCurrent = sourceIsCurrent
        connection = service.connection; organization = draft.destination?.orgID ?? ""
        channel = draft.channelID; thread = draft.threadID
        attemptID = draft.attemptID; attemptAuthor = draft.attemptAuthor
        attemptSessionAuthor = draft.attemptSessionAuthor
        if submitted { status = "Delivery is unknown. Retry this attempt or start over." }
    }

    var key: ChatOrgKey? {
        destination?.chatKey
    }
    var online: Bool {
        guard active, isOpen(), let key, let connection, let current = service.connection,
              current.server == connection.server, current.accountId == connection.accountId,
              current.orgKey == key, current.sessionId == connection.sessionId, service.isServerKnown(service, key),
              ChatNotifications.allowed(service, key, channel: nil) else { return false }
        return true
    }
    var organizations: [Destination] {
        guard online, let key else { return [] }
        // The server client currently connects one organization at a time.
        // Only that confirmed membership is eligible; cached organizations
        // must never become destinations after an account switch.
        return [.init(id: key.orgId, title: (try? service.orgSessions[key]?.store?.orgName) ?? "Organization")]
    }
    var outgoingText: String { AgentAnswerText.forSending(text, maxBytes: ChatChannelModel.maxBytes) }
    // The answer is a local snapshot; copying it needs no destination connection.
    var readable: Bool { active && isOpen() }
    var truncated: Bool { text.utf8.count > ChatChannelModel.maxBytes }
    var canSend: Bool {
        canCompose && canUseSession
    }
    var canSendAsUser: Bool { canCompose }
    private var canUseSession: Bool {
        caller != nil && sourceIsCurrent() && key.map { service.supports("chat.session_tools", key: $0) } == true
    }
    private var canCompose: Bool {
        online && !sending && !loading && !submitted
            && channels.contains { $0.id == channel }
            && (thread.isEmpty || threads.contains { $0.id == thread })
            && ChatChannelModel.textProblem(outgoingText) == nil
    }
    var canRetry: Bool {
        guard online, !sending, submitted, !channel.isEmpty else { return false }
        switch attemptAuthor {
        case .session: return attemptSessionAuthor != nil && canUseSession
        case .account: return true
        case nil: return false
        }
    }
    var signature: String {
        if let author = attemptSessionAuthor {
            return author.field == "author_agent_id" ? (service.localAgent(author.value)?.name ?? author.value) : author.value
        }
        guard online, let caller, let key, let store = service.orgSessions[key]?.store,
              let generation = try? store.queue.read({ try String.fetchOne($0, sql: "SELECT generation FROM meta WHERE id = 1") }),
              let author = try? service.sessionAuthor(key, caller: caller, generation: generation) else { return sourceTitle }
        return author.field == "author_agent_id" ? (service.localAgent(author.value)?.name ?? caller.signature) : author.value
    }

    func loadInitialDestinations() async {
        guard !initialDestinationsLoaded else { return }
        initialDestinationsLoaded = true
        await loadChannels(preservingSelection: true)
    }

    func loadChannels(more: Bool = false, preservingSelection: Bool = false) async {
        channelRevision += 1
        let ticket = channelRevision
        if !more {
            threadRevision += 1; loadingThreads = false
            channels = []; threads = []; moreChannels = nil; moreThreads = nil
            if !preservingSelection { channel = ""; thread = "" }
        }
        guard online else { loadingChannels = false; return }
        loadingChannels = true; problem = nil
        defer { if channelRevision == ticket { loadingChannels = false } }
        do {
            var args: [String: ChatJSON] = ["tool": .string("chat_channels"), "org_id": .string(organization)]
            if more, let moreChannels { args["after"] = .string(moreChannels) }
            let result = try await readDestination(args)
            guard channelRevision == ticket, online else { return }
            guard case .array(let rows) = result["channels"] else { throw ChatSessionTools.Failure(code: "unsupported") }
            for row in rows where row["can_post"] == .bool(true) {
                guard let id = row["channel_id"]?.string, let name = row["name"]?.string,
                      !channels.contains(where: { $0.id == id }) else { continue }
                channels.append(.init(id: id, title: "\(row["team_name"]?.string ?? "") / #\(name)"))
            }
            moreChannels = result["next"]?.string
            if preservingSelection, channels.contains(where: { $0.id == channel }) {
                await loadThreads(preservingSelection: true)
            }
        } catch { if channelRevision == ticket { problem = Self.message(error) } }
    }

    func loadThreads(more: Bool = false, preservingSelection: Bool = false) async {
        threadRevision += 1
        let ticket = threadRevision
        if !more { threads = []; moreThreads = nil; if !preservingSelection { thread = "" } }
        guard online, !channel.isEmpty else { loadingThreads = false; return }
        loadingThreads = true; problem = nil
        defer { if threadRevision == ticket { loadingThreads = false } }
        do {
            var args: [String: ChatJSON] = ["tool": .string("chat_read"), "org_id": .string(organization), "channel_id": .string(channel)]
            if more, let moreThreads { args["before"] = .number(Double(moreThreads)) }
            let result = try await readDestination(args)
            guard threadRevision == ticket, online else { return }
            guard let messages = result["messages"] else { throw ChatSessionTools.Failure(code: "unsupported") }
            let rows = try JSONDecoder().decode([ChatMessageWire].self, from: JSONEncoder().encode(messages))
            for row in rows where row.threadRootId == nil && row.deletedAt == nil && !threads.contains(where: { $0.id == row.messageId }) {
                threads.append(.init(id: row.messageId, title: String(row.text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(100))))
            }
            moreThreads = result["next"]?.int
        } catch { if threadRevision == ticket { problem = Self.message(error) } }
    }

    /// Explicit session sending. Opening, editing, copying, selecting a
    /// destination and closing the tab never enqueue a command.
    func send() async {
        guard canSend else { return }
        await sendFromSession()
    }

    func retry() async {
        guard canRetry else { return }
        if attemptAuthor == .session { await sendFromSession() }
        else { await sendFromAccount() }
    }

    private func sendFromSession() async {
        sending = true; problem = nil; status = nil
        defer { sending = false }
        do {
            let revision = editRevision
            var args: [String: ChatJSON] = ["tool": .string("chat_post"), "org_id": .string(organization),
                "channel_id": .string(channel), "text": .string(outgoingText)]
            if !thread.isEmpty { args["thread_root_id"] = .string(thread) }
            let id = attemptID ?? UUID()
            args["message_id"] = .string(id.uuidString.lowercased())
            let result = try await call(args, revision: revision) { generation in
                // Preflight can outlive a closed tab. Record the attempt only
                // at the synchronous boundary immediately before queueing.
                guard let key = self.key, let caller = self.caller else { throw ChatError.notConnected }
                let author = try self.attemptSessionAuthor ?? self.service.sessionAuthor(key, caller: caller, generation: generation)
                self.attemptID = id; self.attemptAuthor = .session
                self.attemptSessionAuthor = author
                self.changed(); try self.persist()
                return author
            }
            status = result["status"]?.string == "sent" ? "Sent." : "Queued for delivery. Check the destination chat for delivery status."
        } catch {
            sendFailed(error)
        }
    }

    private func call(_ args: [String: ChatJSON], revision: Int? = nil,
                      preparePost: @MainActor (String) throws -> ChatSessionAuthor? = { _ in nil }) async throws -> ChatJSON {
        guard online, let caller else { throw ChatSessionTools.Failure(code: "not_connected") }
        let destinationVersion: String?
        if args["tool"]?.string == "chat_post", let key, let store = service.orgSessions[key]?.store {
            destinationVersion = try destinationRevision(store, channel: channel, thread: thread)
        } else { destinationVersion = nil }
        return try await ChatSessionTools.call(.object(args), caller: caller, service: service,
            isCallerWaiting: { [weak self] in self?.active == true }, preparePost: preparePost) { [weak self] in
                guard let self, self.online, self.sourceIsCurrent(), revision == nil || revision == self.editRevision else { throw AgentAnswerTranscript.Problem.changed }
                if let destinationVersion {
                    guard let key = self.key, let store = self.service.orgSessions[key]?.store,
                          try self.destinationRevision(store, channel: self.channel, thread: self.thread) == destinationVersion else { throw AgentAnswerTranscript.Problem.changed }
                }
                return true
            }
    }

    /// Destination discovery from an account never manufactures a local caller.
    private func readDestination(_ args: [String: ChatJSON]) async throws -> ChatJSON {
        if caller != nil && sourceIsCurrent(), let key, service.supports("chat.session_tools", key: key) { return try await call(args) }
        let capture = try accessStamp()
        guard let key, let token = service.token, let store = service.orgSessions[key]?.store else { throw ChatError.notConnected }
        let api = service.makeAPI(key.server)
        if args["tool"]?.string == "chat_channels" {
            let page = try await api.channelsPage(key.orgId, after: args["after"]?.string, token: token)
            guard try accessStamp() == capture else { throw ChatError.notConnected }
            let names = try await store.queue.read { db in
                Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT team_id, name FROM teams WHERE mine = 1 AND archived_at IS NULL").map { ($0["team_id"] as String, $0["name"] as String) })
            }
            guard try accessStamp() == capture else { throw ChatError.notConnected }
            return .object(["channels": .array(page.channels.compactMap { card in
                guard let team = names[card.teamId] else { return nil }
                return .object(["channel_id": .string(card.channelId), "name": .string(card.name), "team_name": .string(team), "can_post": .bool(!card.archived)])
            }), "next": page.next.map(ChatJSON.string) ?? .null])
        }
        guard let channel = args["channel_id"]?.string else { throw ChatError.notConnected }
        let page = try await api.messagesPage(key.orgId, channel: channel, root: nil, before: args["before"]?.int, token: token)
        guard try accessStamp() == capture, ChatNotifications.allowed(service, key, channel: channel) else { throw ChatError.notConnected }
        return .object(["messages": try JSONDecoder().decode(ChatJSON.self, from: JSONEncoder().encode(page.messages)),
            "next": page.next.map { .number(Double($0)) } ?? .null])
    }
    private struct Access: Equatable {
        let session: String
        let generation: String
        let epoch: Int
        let store: ObjectIdentifier
    }
    private func accessStamp() throws -> Access {
        guard online, let key, let session = connection?.sessionId, let store = service.orgSessions[key]?.store else { throw ChatError.notConnected }
        return try store.queue.read { db in
            guard let generation = try String.fetchOne(db, sql: "SELECT generation FROM meta WHERE id = 1") else { throw ChatError.notConnected }
            return Access(session: session, generation: generation,
                epoch: try Int.fetchOne(db, sql: "SELECT channel_access_epoch FROM meta WHERE id = 1") ?? -1, store: ObjectIdentifier(store))
        }
    }
    var accountSignature: String { key?.accountId ?? "" }
    func refreshDestinations() async {
        guard !sending, let current = service.connection,
              destination == nil || current.orgKey == destination?.chatKey else { return }
        destination = destination ?? current.orgKey.map(OrgKey.init)
        connection = current; organization = destination?.orgID ?? ""
        await loadChannels(preservingSelection: attemptID != nil)
    }
    func sendAsUser() async {
        guard canSendAsUser else { return }
        await sendFromAccount()
    }
    private func sendFromAccount() async {
        guard let key, let token = service.token, let store = service.orgSessions[key]?.store else { return }
        sending = true; problem = nil; status = nil
        defer { sending = false }
        do {
            let capture = try accessStamp(), revision = editRevision
            let selectedChannel = channel, selectedThread = thread, message = outgoingText
            let before = try destinationRevision(store, channel: selectedChannel, thread: selectedThread)
            let api = service.makeAPI(key.server)
            var cursor: String?, seen = Set<String>(), found: ChatChannelCard?
            repeat {
                let page = try await api.channelsPage(key.orgId, after: cursor, token: token)
                guard try accessStamp() == capture, editRevision == revision else { throw AgentAnswerTranscript.Problem.changed }
                found = page.channels.first { $0.channelId == selectedChannel }
                cursor = page.next
                if let cursor, !seen.insert(cursor).inserted { throw ChatError.notConnected }
            } while found == nil && cursor != nil
            guard let found, !found.archived else { throw ChatError.notConnected }
            guard before.hasPrefix("\(found.teamId)|\(found.version)|") else { throw AgentAnswerTranscript.Problem.changed }
            let page = try await api.messagesPage(key.orgId, channel: selectedChannel, root: selectedThread.isEmpty ? nil : selectedThread, before: nil, token: token)
            guard selectedThread.isEmpty || page.messages.contains(where: { $0.messageId == selectedThread && $0.deletedAt == nil && $0.threadRootId == nil }) else { throw ChatError.notConnected }
            let id = attemptID ?? UUID(), messageID = id.uuidString.lowercased()
            let recorded = try await store.queue.read {
                try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE message_id = ?)", arguments: [messageID]) == true
            }
            guard try accessStamp() == capture, editRevision == revision,
                  try destinationRevision(store, channel: selectedChannel, thread: selectedThread) == before else { throw AgentAnswerTranscript.Problem.changed }
            attemptID = id; attemptAuthor = .account; changed(); try persist()
            // No suspension after the final rights/revision check and before
            // the normal account post is committed with this stable ID.
            if recorded {
                try service.retry(key, messageId: messageID)
            } else {
                try service.post(key, channel: selectedChannel, root: selectedThread.isEmpty ? nil : selectedThread,
                    text: message, mentions: [], messageId: messageID)
            }
            status = "Queued from your account. Check the destination chat for delivery status."
        } catch {
            sendFailed(error)
        }
    }
    private func sendFailed(_ error: Error) {
        problem = Self.message(error)
        if submitted { status = "Delivery is unknown. Retry this attempt or start over." }
    }
    private func destinationRevision(_ store: ChatStore, channel: String, thread: String) throws -> String {
        guard let key, ChatNotifications.allowed(service, key, channel: channel) else { throw ChatError.notConnected }
        return try store.queue.read { db in
            guard let card = try Row.fetchOne(db, sql: "SELECT c.team_id, c.version, c.archived, t.mine, (t.archived_at IS NOT NULL) AS team_archived FROM channels c JOIN teams t ON t.team_id = c.team_id WHERE channel_id = ?", arguments: [channel]),
                  !(card["archived"] as Bool), card["mine"] as Bool, !(card["team_archived"] as Bool) else { throw ChatError.notConnected }
            let root = thread.isEmpty ? nil : try Row.fetchOne(db, sql: "SELECT revision, deleted_at, thread_root_id FROM messages WHERE message_id = ? AND channel_id = ?", arguments: [thread, channel])
            if let root, (root["deleted_at"] as String?) != nil || (root["thread_root_id"] as String?) != nil { throw ChatError.notConnected }
            return "\(card["team_id"] as String)|\(card["version"] as Int)|\(root?["revision"] as Int? ?? -1)"
        }
    }
    var canStartAnotherAttempt: Bool { active && isOpen() && submitted && !sending }
    func startAnotherAttempt() {
        guard canStartAnotherAttempt, let id = attemptID else { return }
        restartConfirmation.request(.init(tabID: tabID, targetID: id.uuidString), title: "Start over?",
            consequences: "The message may already have been delivered. Starting over can post a duplicate.", verb: "Start Over", cancelTitle: "Cancel",
            stillValid: { [weak self] in self?.canStartAnotherAttempt == true && self?.attemptID == id }) { [weak self] in
                guard let self else { return }
                self.attemptID = nil; self.attemptAuthor = nil; self.attemptSessionAuthor = nil
                self.status = nil; self.problem = nil; self.changed(); try self.persist()
            }
    }

    static func message(_ error: Error) -> String {
        if let error = error as? AgentAnswerTranscript.Problem { return error.rawValue }
        if let error = error as? ChatSessionTools.Failure {
            switch error.code {
            case "busy": return "Another message from this tab is still being sent. Check the chat before retrying."
            case "rate_limited": return "Too many messages. Wait before retrying."
            case "unsupported": return "This server does not support forwarding from an agent session."
            default: break
            }
        }
        return "The destination is unavailable or the connection changed. Check the chat before retrying; you can still copy or save the text."
    }
}
