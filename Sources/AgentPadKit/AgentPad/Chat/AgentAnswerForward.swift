import AppKit
import GRDB
import Observation

@MainActor
@Observable
final class AgentAnswerForward {
    struct Destination: Identifiable, Equatable { var id: String; var title: String }
    let caller: ChatLocalCaller
    let sourceTitle: String
    let service: ChatService
    let connection: ChatConnection?
    var text: String
    var organization = ""
    var channel = ""
    var thread = ""
    var channels: [Destination] = []
    var threads: [Destination] = []
    var moreChannels: String?
    var moreThreads: Int?
    var loadingChannels = false
    var loadingThreads = false
    var loading: Bool { loadingChannels || loadingThreads }
    var sending = false
    var submitted = false
    var status: String?
    var problem: String?
    var active = true
    @ObservationIgnored var sourceIsCurrent: @MainActor () -> Bool
    @ObservationIgnored private var channelRevision = 0
    @ObservationIgnored private var threadRevision = 0
    @ObservationIgnored private var attempt: [String: ChatJSON]?

    init(text: String, caller: ChatLocalCaller, sourceTitle: String, service: ChatService,
         sourceIsCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.text = text; self.caller = caller; self.sourceTitle = sourceTitle; self.service = service
        self.connection = service.connection; self.sourceIsCurrent = sourceIsCurrent
        organization = service.connection?.orgId ?? ""
    }

    var key: ChatOrgKey? {
        guard let connection, !organization.isEmpty else { return nil }
        return ChatOrgKey(server: connection.server, accountId: connection.accountId, orgId: organization)
    }
    var online: Bool {
        guard active, let key, let connection, let current = service.connection,
              current.server == connection.server, current.accountId == connection.accountId,
              current.sessionId == connection.sessionId, service.isServerKnown(service, key),
              ChatNotifications.allowed(service, key, channel: nil) else { return false }
        return service.supports("chat.session_tools", key: key)
    }
    var organizations: [Destination] {
        guard online, let key else { return [] }
        // The server client currently connects one organization at a time.
        // Only that confirmed membership is eligible; cached organizations
        // must never become destinations after an account switch.
        return [.init(id: key.orgId, title: (try? service.orgSessions[key]?.store?.orgName) ?? "Organization")]
    }
    var outgoingText: String { AgentAnswerText.forSending(text, maxBytes: ChatChannelModel.maxBytes) }
    var truncated: Bool { text.utf8.count > ChatChannelModel.maxBytes }
    var canSend: Bool {
        online && !sending && !submitted && !loading && sourceIsCurrent()
            && channels.contains { $0.id == channel }
            && (thread.isEmpty || threads.contains { $0.id == thread })
            && ChatChannelModel.textProblem(outgoingText) == nil
    }
    var signature: String {
        guard online, let key, let store = service.orgSessions[key]?.store,
              let generation = try? store.queue.read({ try String.fetchOne($0, sql: "SELECT generation FROM meta WHERE id = 1") }),
              let author = try? service.sessionAuthor(key, caller: caller, generation: generation) else { return caller.signature }
        return author.field == "author_agent_id" ? (service.localAgent(author.value)?.name ?? caller.signature) : author.value
    }

    func loadChannels(more: Bool = false) async {
        channelRevision += 1
        let ticket = channelRevision
        if !more {
            threadRevision += 1; loadingThreads = false
            channels = []; threads = []; channel = ""; thread = ""; moreChannels = nil; moreThreads = nil
        }
        guard online else { loadingChannels = false; return }
        loadingChannels = true; problem = nil
        defer { if channelRevision == ticket { loadingChannels = false } }
        do {
            var args: [String: ChatJSON] = ["tool": .string("chat_channels"), "org_id": .string(organization)]
            if more, let moreChannels { args["after"] = .string(moreChannels) }
            let result = try await call(args)
            guard channelRevision == ticket, online else { return }
            guard case .array(let rows) = result["channels"] else { throw ChatSessionTools.Failure(code: "unsupported") }
            for row in rows where row["can_post"] == .bool(true) {
                guard let id = row["channel_id"]?.string, let name = row["name"]?.string,
                      !channels.contains(where: { $0.id == id }) else { continue }
                channels.append(.init(id: id, title: "\(row["team_name"]?.string ?? "") / #\(name)"))
            }
            moreChannels = result["next"]?.string
        } catch { if channelRevision == ticket { problem = Self.message(error) } }
    }

    func loadThreads(more: Bool = false) async {
        threadRevision += 1
        let ticket = threadRevision
        if !more { threads = []; thread = ""; moreThreads = nil }
        guard online, !channel.isEmpty else { loadingThreads = false; return }
        loadingThreads = true; problem = nil
        defer { if threadRevision == ticket { loadingThreads = false } }
        do {
            var args: [String: ChatJSON] = ["tool": .string("chat_read"), "org_id": .string(organization), "channel_id": .string(channel)]
            if more, let moreThreads { args["before"] = .number(Double(moreThreads)) }
            let result = try await call(args)
            guard threadRevision == ticket, online else { return }
            guard let messages = result["messages"] else { throw ChatSessionTools.Failure(code: "unsupported") }
            let rows = try JSONDecoder().decode([ChatMessageWire].self, from: JSONEncoder().encode(messages))
            for row in rows where row.threadRootId == nil && row.deletedAt == nil && !threads.contains(where: { $0.id == row.messageId }) {
                threads.append(.init(id: row.messageId, title: String(row.text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(100))))
            }
            moreThreads = result["next"]?.int
        } catch { if threadRevision == ticket { problem = Self.message(error) } }
    }

    /// The only mutation entry point. Opening, editing, copying, selecting a
    /// destination and closing the window never enqueue a command.
    func send() async {
        guard canSend else { return }
        sending = true; problem = nil; status = nil
        defer { sending = false }
        do {
            var args: [String: ChatJSON] = ["tool": .string("chat_post"), "org_id": .string(organization),
                "channel_id": .string(channel), "text": .string(outgoingText)]
            if !thread.isEmpty { args["thread_root_id"] = .string(thread) }
            if let attempt, attempt.filter({ $0.key != "message_id" }) == args { args = attempt }
            else { args["message_id"] = .string(UUID().uuidString.lowercased()); attempt = args }
            let result = try await call(args)
            submitted = true
            status = result["status"]?.string == "sent" ? "Sent." : "Queued for delivery. Check the destination chat for delivery status."
        } catch {
            problem = Self.message(error)
            // A disconnect may lose the reply after the durable post exists.
            // Do not offer a second send with a different message ID.
            if let key, let id = attempt?["message_id"]?.string, let store = service.orgSessions[key]?.store,
               (try? await store.queue.read({ try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM session_posts WHERE message_id = ?)", arguments: [id]) })) == true {
                submitted = true
                status = "A send attempt is recorded. Check the destination chat for delivery status."
            }
        }
    }

    private func call(_ args: [String: ChatJSON]) async throws -> ChatJSON {
        guard online else { throw ChatSessionTools.Failure(code: "not_connected") }
        return try await ChatSessionTools.call(.object(args), caller: caller, service: service,
            isCallerWaiting: { [weak self] in self?.active == true }) { [weak self] in
                guard let self, self.online, self.sourceIsCurrent() else { throw AgentAnswerTranscript.Problem.changed }
                return true
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
