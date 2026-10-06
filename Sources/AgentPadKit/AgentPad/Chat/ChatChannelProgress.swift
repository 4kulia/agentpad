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
    var answer: String? = nil

    var word: String {
        switch state {
        case "pending", "submitted": return "queued"
        case "awaiting_decision": return "waiting for the owner's decision"
        case "approved", "starting": return "starting…"
        case "running": return "working…"
        case "finished":
            switch publication {
            case "published": return "answered"
            case "awaiting_publish": return "finished · awaiting publication"
            case "withheld": return "finished · answer withheld"
            case "publish_failed": return "finished · not published: " + ChatChannelRequests.reason(error)
            default: return "finished · not published"
            }
        default: return state.replacingOccurrences(of: "_", with: " ") + (error.map { ": \($0)" } ?? "")
        }
    }

    static func read(_ db: Database, channel: String) throws -> [Self] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT r.*, coalesce(a.name, r.agent_name, 'Agent') AS display_name,
                (SELECT m.message_id FROM messages m WHERE m.run_id = r.run_id AND m.channel_id = r.channel_id
                    AND m.deleted_at IS NULL LIMIT 1) AS answer FROM requests r
            JOIN channels c ON c.channel_id = r.channel_id
            LEFT JOIN agent_channels a ON a.channel_id = r.channel_id AND a.agent_id = r.agent_id
            WHERE r.channel_id = ? AND r.source_message_id IS NOT NULL ORDER BY r.created_at, r.request_id
            """, arguments: [channel])
        let requests: [Self] = rows.map { row in
            let publish: String? = row["publish_reason"]
            let failure: String? = row["failure_reason"]
            let declined: String? = row["decline_reason"]
            let cause: String? = row["cause"]
            return Self(id: row["request_id"], source: row["source_message_id"], agent: row["display_name"], state: row["state"],
                        initiator: row["initiator_account_id"], owner: row["owner_account_id"], publication: row["publication"],
                        error: publish ?? failure ?? declined ?? cause, answer: row["answer"])
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
        MainThreadWatchdog.shared.checkpoint()
        guard let key = connection?.orgKey, key.orgId == org, type == "run.activity",
              let id = body["request_id"]?.string, let text = body["text"]?.string,
              let request = try? orgSessions[key]?.store?.calls.request(id), request.kind == "channel", !request.state.isFinal,
              let channel = request.channelId, channelAgentAllowed(key, channel: channel) else { return }
        let displayText = String(text.prefix(240))
        let changed = channelActivity[id]?.key != key || channelActivity[id]?.text != displayText
            || (channelActivity[id]?.expires ?? .distantPast) <= now
        channelActivity[id] = ChatChannelActivity(key: key, request: id, text: displayText, expires: now.addingTimeInterval(15))
        if changed { channelActivityChanges.schedule() }
        scheduleChannelActivityExpiry()
    }

    func activity(_ key: ChatOrgKey, request id: String, now: Date = Date()) -> String? {
        _ = channelActivityRevision
        guard let entry = channelActivity[id], entry.key == key, entry.expires > now, isServerKnown(self, key),
              let request = try? orgSessions[key]?.store?.calls.request(id), !request.state.isFinal,
              let channel = request.channelId, channelAgentAllowed(key, channel: channel) else { return nil }
        return entry.text
    }

    func pruneChannelActivity(now: Date = Date()) {
        let kept = channelActivity.filter { activity($0.value.key, request: $0.key, now: now) != nil }
        if kept.count != channelActivity.count {
            channelActivity = kept
            channelActivityRevision += 1
        }
        if kept.isEmpty {
            channelActivityExpiry?.cancel()
            channelActivityExpiry = nil
            channelActivityChanges.cancel()
        }
        else { scheduleChannelActivityExpiry() }
    }

    private func scheduleChannelActivityExpiry() {
        guard channelActivityExpiry == nil, let next = channelActivity.values.map(\.expires).min() else { return }
        let delay = max(0.01, next.timeIntervalSinceNow)
        channelActivityExpiry = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.channelActivityExpiry = nil
            self.pruneChannelActivity()
        }
    }

    func clearChannelActivity() {
        channelActivityExpiry?.cancel()
        channelActivityExpiry = nil
        channelActivityChanges.cancel()
        guard !channelActivity.isEmpty else { return }
        channelActivity.removeAll()
        channelActivityRevision += 1
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

/// Chooses only existing actions. Display state never grants execution rights.
struct ChatSourcePresentation: Equatable {
    enum Action { case stop, cancel, none }
    enum Tone { case running, attention, failure, success }
    var action: Action
    var tone: Tone
    var answered: Bool
    var showsActivity: Bool

    init(_ status: ChatSourceStatus, me: String, connected: Bool) {
        answered = status.state == "finished" && status.publication == "published"
        showsActivity = connected && ["starting", "running"].contains(status.state)
        if answered { tone = .success }
        else if ["failed", "declined", "cancelled", "stopped", "lost"].contains(status.state) || status.publication == "publish_failed" { tone = .failure }
        else if ["starting", "running"].contains(status.state) { tone = .running }
        else { tone = .attention }
        if status.owner == me && ["starting", "running"].contains(status.state) { action = .stop }
        else if status.local && status.state == "pending" || status.initiator == me && ["submitted", "awaiting_decision", "approved"].contains(status.state) { action = .cancel }
        else { action = .none }
    }
}

struct ChatSourceProgress: View {
    let model: ChatChannelModel
    let source: String
    @State private var problem: String?
    @State private var expanded = false
    @State private var details: ChatSourceStatus?
    @State private var window = WindowBox()
    private var connected: Bool { model.service.isServerKnown(model.service, model.key) }
    private var statuses: [ChatSourceStatus] { model.sourceStatuses.filter { $0.source == source } }

    var body: some View {
        if !statuses.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(expanded ? statuses : Array(statuses.prefix(3))) { status in card(status) }
                if statuses.count > 3 {
                    Button(expanded ? "Show less" : "\(statuses.count - 3) more requests") { expanded.toggle() }.buttonStyle(.link)
                }
                if let problem { Text(problem).foregroundStyle(ChatAppearance.failure) }
            }.font(Theme.display(10)).padding(.vertical, 6)
                .background(WindowReader(box: window))
                .onChange(of: statuses) { old, new in
                    for status in new {
                        if let previous = old.first(where: { $0.id == status.id }),
                           let announcement = ChatAccessibility.agent(from: previous, to: status) {
                            ChatAccessibility.announce(announcement, in: window.view)
                        }
                    }
                }
                .popover(item: $details) { status in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(status.agent).font(Theme.display(13, weight: .semibold)); ChatBotBadge() }
                        Text(model.sourceStatusWord(status)).textSelection(.enabled)
                        if let activity = model.service.activity(model.key, request: status.id) { Text(activity).textSelection(.enabled) }
                        if !connected { Text("Offline · status may have changed") }
                    }.font(Theme.display(11)).padding(16).frame(width: 300)
                }
        }
    }

    private func card(_ status: ChatSourceStatus) -> some View {
        let presentation = ChatSourcePresentation(status, me: model.key.accountId, connected: connected)
        let color: Color = switch presentation.tone {
        case .running: ChatAppearance.accent
        case .attention: ChatAppearance.attention
        case .failure: ChatAppearance.failure
        case .success: ChatAppearance.success
        }
        return HStack(spacing: 10) {
            Image(systemName: presentation.answered ? "checkmark.circle" : presentation.tone == .failure ? "exclamationmark.circle" : "sparkles")
                .font(.system(size: presentation.answered ? 14 : 22)).foregroundStyle(color).frame(width: 27)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(status.agent).font(Theme.display(11, weight: .medium)).lineLimit(1)
                    ChatBotBadge()
                    if presentation.answered { Text("answered").foregroundStyle(color) }
                }
                if !presentation.answered {
                    Text(model.sourceStatusWord(status)).foregroundStyle(color).lineLimit(2)
                    if presentation.showsActivity, let activity = model.service.activity(model.key, request: status.id) {
                        Text(activity).font(Theme.mono(9)).foregroundStyle(ChatAppearance.secondary).lineLimit(1).help(activity)
                    }
                }
                if !connected { Text("Offline · status may have changed").foregroundStyle(ChatAppearance.secondary) }
            }
            Spacer(minLength: 0)
            if presentation.action == .stop {
                ChatIconButton(title: "Stop agent", symbol: "stop.circle") {
                    problem = model.service.askToEnd(model.key, status.id, type: "request.stop", states: [.starting, .running])
                }
            } else if presentation.action == .cancel {
                ChatIconButton(title: "Cancel request", symbol: "xmark.circle") { problem = model.service.cancelChannelIntent(model.key, request: status.id) }
            }
            if presentation.answered, let answer = status.answer, let message = model.message(answer) {
                ChatIconButton(title: "Go to answer", symbol: "arrow.turn.down.right") { model.navigate(to: message) }
            }
            ChatIconButton(title: "Request details", symbol: "ellipsis") { details = status }
        }
        .padding(.horizontal, 12).padding(.vertical, presentation.answered ? 6 : 10)
        .frame(minHeight: presentation.answered ? 32 : 64)
        .background(color.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.20)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status.agent), BOT, \(model.sourceStatusWord(status))\(connected ? "" : ", Offline, status may have changed")")
    }
}
