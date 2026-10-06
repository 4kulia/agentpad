import Foundation
import GRDB
import SwiftUI

struct ChatSourceStatus: Equatable, Identifiable, Sendable {
    var id: String
    var source: String
    var agent: String
    var state: String
    var initiator: String?
    var owner: String?
    var publication: String?
    var error: String?
    var local = false

    var word: String {
        switch state {
        case "pending", "submitted": return "queued"
        case "awaiting_decision": return "waiting for the owner's decision"
        case "approved", "starting": return "starting…"
        case "running": return "working…"
        case "finished":
            return publication == "published" ? "answered" : publication == "awaiting_publish" ? "finished · preparing publication" : (publication ?? "finished")
        default: return state.replacingOccurrences(of: "_", with: " ") + (error.map { ": \($0)" } ?? "")
        }
    }

    static func read(_ db: Database, channel: String) throws -> [Self] {
        let requests = try Row.fetchAll(db, sql: """
            SELECT r.*, coalesce(a.name, r.agent_name, 'Agent') AS display_name FROM requests r
            JOIN channels c ON c.channel_id = r.channel_id
            LEFT JOIN agent_channels a ON a.channel_id = r.channel_id AND a.agent_id = r.agent_id
            WHERE r.channel_id = ? AND r.source_message_id IS NOT NULL ORDER BY r.created_at, r.request_id
            """, arguments: [channel]).map { row in
                Self(id: row["request_id"], source: row["source_message_id"], agent: row["display_name"], state: row["state"],
                     initiator: row["initiator_account_id"], owner: row["owner_account_id"], publication: row["publication"], error: row["publish_reason"])
            }
        let pending = try Row.fetchAll(db, sql: """
            SELECT i.*, o.state, o.error, coalesce(a.name, 'Agent') AS display_name FROM channel_call_intents i
            JOIN channel_sends s ON s.message_id = i.message_id JOIN channels c ON c.channel_id = s.channel_id
            JOIN outbox o ON o.command_id = i.command_id
            LEFT JOIN agent_channels a ON a.channel_id = s.channel_id AND a.agent_id = i.agent_id
            WHERE s.channel_id = ? AND i.cancelled = 0 AND NOT EXISTS(SELECT 1 FROM requests r WHERE r.request_id = i.request_id AND r.has_fixed)
            """, arguments: [channel]).map { row in
                Self(id: row["request_id"], source: row["message_id"], agent: row["display_name"], state: row["state"], error: row["error"], local: true)
            }
        return requests + pending
    }
}

struct ChatChannelActivity: Equatable {
    var key: ChatOrgKey
    var request: String
    var text: String
    var expires: Date
}

extension ChatService {
    func sourceStatusWord(_ status: ChatSourceStatus, key: ChatOrgKey) -> String {
        if status.state == "finished", status.publication == "awaiting_publish" {
            if (try? journal?.automaticRequestBlocked(key, request: status.id)) == true { return "finished · automatic publication cancelled" }
            if let issue = channelPublicationIssue(key, requestId: status.id) { return "finished · " + issue }
        }
        return status.word
    }

    func receiveChannelActivity(org: String, type: String, body: ChatJSON, now: Date = Date()) {
        guard let key = connection?.orgKey, key.orgId == org, type == "run.activity",
              let id = body["request_id"]?.string, let text = body["text"]?.string,
              let request = try? orgSessions[key]?.store?.calls.request(id), request.kind == "channel", !request.state.isFinal,
              let channel = request.channelId, channelAgentAllowed(key, channel: channel) else { return }
        channelActivity[id] = ChatChannelActivity(key: key, request: id, text: String(text.prefix(240)), expires: now.addingTimeInterval(15))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.pruneChannelActivity()
        }
    }

    func activity(_ key: ChatOrgKey, request id: String, now: Date = Date()) -> String? {
        guard let entry = channelActivity[id], entry.key == key, entry.expires > now, isServerKnown(self, key),
              let request = try? orgSessions[key]?.store?.calls.request(id), !request.state.isFinal,
              let channel = request.channelId, channelAgentAllowed(key, channel: channel) else { return nil }
        return entry.text
    }

    func pruneChannelActivity(now: Date = Date()) {
        channelActivity = channelActivity.filter { activity($0.value.key, request: $0.key, now: now) != nil }
    }

    static func channelAction(_ text: String) -> String {
        let tool = text.split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "(" }).first?.lowercased() ?? ""
        switch tool {
        case "read", "reading": return "Reading files"
        case "edit", "write", "editing", "writing": return "Editing files"
        case "grep", "glob", "search", "searching": return "Searching files"
        case "bash", "running": return "Running a command"
        case "websearch", "webfetch": return "Reading web sources"
        default: return "Working"
        }
    }
}

struct ChatSourceProgress: View {
    let model: ChatChannelModel
    let source: String
    @State private var problem: String?
    var body: some View {
        let statuses = model.sourceStatuses.filter { $0.source == source }
        if !statuses.isEmpty {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(statuses) { status in
                        HStack {
                            Text("\(status.agent) · \(model.service.sourceStatusWord(status, key: model.key))")
                            if let activity = model.service.activity(model.key, request: status.id, now: timeline.date) { Text(activity).foregroundStyle(.secondary) }
                            Spacer()
                            if status.owner == model.key.accountId && ["starting", "running"].contains(status.state) {
                                Button("Stop") { problem = model.service.askToEnd(model.key, status.id, type: "request.stop", states: [.starting, .running]) }
                            } else if status.local && status.state == "pending" || status.initiator == model.key.accountId && ["submitted", "awaiting_decision", "approved"].contains(status.state) {
                                Button("Cancel") { problem = model.service.cancelChannelIntent(model.key, request: status.id) }
                            }
                        }
                    }
                    if let problem { Text(problem).foregroundStyle(.red) }
                }.font(.caption).padding(.vertical, 3)
            }
        }
    }
}
