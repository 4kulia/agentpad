import AppKit
import Foundation
import GRDB

/// Chat notices (DESIGN-F4): one per message or request, never with
/// anything of what it is about — a title only; details are in the app,
/// behind F2's gate. Taken back when they no longer apply.
@MainActor
enum ChatNotifications {
    /// Shows a notice; the system's outside tests.
    static var post: @MainActor (_ id: String, _ title: String) -> Void = { id, title in
        guard AgentPadSettingsModel.shared.notificationsEnabled else { return }
        AttentionCoordinator.shared.notificationManager?.postChat(id: id, title: title)
    }
    /// Takes notices back by id or id prefix.
    static var remove: @MainActor (_ ids: [String], _ prefix: String?) -> Void = { ids, prefix in
        AttentionCoordinator.shared.notificationManager?.removeChat(ids: ids, prefix: prefix)
    }

    /// The Dock's badge counts again; nothing outside the app in tests.
    static var badgeChanged: @MainActor () -> Void = { if NSApp != nil { AttentionCoordinator.shared.refreshBadge() } }

    /// The account is in it: another account in the same organization takes it back (review F4c-4).
    static func requestId(_ key: ChatOrgKey, _ request: String) -> String { "chat:\(key.orgId):request:\(request)@\(key.accountId)" }

    /// A request waits for this Mac's decision: one notice per request —
    /// from an event, a snapshot or a start alike — by the marker
    /// `notified('decision', request_id)` in the organization's cache (once
    /// per server generation: its cache is read anew then). Called by the
    /// owner's side where `notify_decision` runs (D4, impl-client-d).
    static func requestAwaitsDecision(_ key: ChatOrgKey, requestId request: String, service: ChatService = .shared) {
        guard let store = service.orgSessions[key]?.store else { return }
        let row = try? store.calls.request(request)
        if row?.kind == "channel" {
            guard let row, service.channelDecisionReady(key, request: row) else { return }
        }
        guard (try? store.queue.write({ db -> Bool in
                  try db.execute(sql: "INSERT OR IGNORE INTO notified (object_id, kind) VALUES (?, 'decision')", arguments: [request])
                  return db.changesCount > 0
              })) == true else { return }
        let id = row?.kind == "channel" ? messageId(key, channel: row?.channelId ?? "", message: "request-\(request)") : requestId(key, request)
        post(id, "A request waits for your decision")
        badgeChanged()
    }

    // MARK: Messages (mentions, replies in my threads)

    static func messageId(_ key: ChatOrgKey, channel: String, message: String) -> String {
        "chat:\(key.orgId):\(channel):\(message)"
    }

    // MARK: The gate, from the service (review F4-A)

    /// F2's gate without the UI: signed in, this organization's connection,
    /// rights confirmed for this session, no snapshot owed, the server has
    /// channels — and, for a channel, its card kept in a team of the user's.
    /// It lives as long as the connection, not the windows.
    static func allowed(_ service: ChatService, _ key: ChatOrgKey, channel: String?) -> Bool {
        guard service.state == .signedIn, let connection = service.connection, connection.orgKey == key,
              let session = service.orgSessions[key], let store = session.store,
              !session.doubtNotWritten, !session.snapshotOwed else { return false }
        let sessionId = connection.sessionId
        return (try? store.queue.read { db -> Bool in
            guard let meta = try Row.fetchOne(db, sql: "SELECT rights_in_doubt, rights_session, channels_served FROM meta WHERE id = 1"),
                  !(meta["rights_in_doubt"] as Bool), (meta["rights_session"] as String?) == sessionId, meta["channels_served"] as Bool
            else { return false }
            guard let channel else { return true }
            return try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM channels c JOIN teams t ON t.team_id = c.team_id WHERE c.channel_id = ? AND t.mine = 1)
                """, arguments: [channel]) ?? false
        }) ?? false
    }

    /// The channel may be seen now; the service's gate, replaced in tests.
    static var visible: @MainActor (ChatService, ChatOrgKey, String) -> Bool = { service, key, channel in
        allowed(service, key, channel: channel)
    }

    /// Mentions not read, of channels that may be seen: the Dock's share.
    static func mentionsForBadge(_ service: ChatService = .shared) -> Int {
        guard let key = service.connection?.orgKey, allowed(service, key, channel: nil),
              let store = service.orgSessions[key]?.store else { return 0 }
        return (try? store.queue.read { db in try ChatUnread.unreadMentions(db) }) ?? 0
    }

    // MARK: Looking (review F4-B)

    /// Places the user may be looking at, each with whether it shows now:
    /// `c:<channel>` — a channel's feed; `t:<root>` — a thread's panel. A
    /// view registers itself with "my window is key and I am in it".
    /// Each place by the views showing it (by view id): a view takes back
    /// only its own entry (review F4b-5).
    static var places: [String: [UUID: @MainActor () -> Bool]] = [:]
    static var appActive: @MainActor () -> Bool = { NSApp?.isActive ?? false }

    /// Looking = the app in front, and that place shown in the key window.
    static func isLooking(_ place: String) -> Bool { appActive() && (places[place]?.values.contains { $0() } ?? false) }

    static func show(_ place: String, view: UUID, _ shown: @escaping @MainActor () -> Bool) { places[place, default: [:]][view] = shown }
    static func hide(_ place: String, view: UUID) {
        places[place]?[view] = nil
        if places[place]?.isEmpty == true { places[place] = nil }
    }

    /// A message the live feed brought (DESIGN-F4): a notice if one is owed
    /// — the channel seen, its marker new — unless the user looks right at
    /// it (the thread's panel for a reply, the feed for a root).
    static func live(_ service: ChatService, _ key: ChatOrgKey, store: ChatStore, channel: String, messageId message: String) {
        guard visible(service, key, channel),
              let owed = (try? store.queue.write({ db -> (kind: String, root: String?)? in
                  guard let kind = try ChatUnread.owe(db, messageId: message, me: key.accountId) else { return nil }
                  let root = try String.fetchOne(db, sql: "SELECT thread_root_id FROM messages WHERE message_id = ?", arguments: [message])
                  return (kind, root)
              })) ?? nil else { return }
        if isLooking(owed.root.map { "t:\($0)" } ?? "c:\(channel)") { return }
        post(messageId(key, channel: channel, message: message), owed.kind == "mention" ? "New mention in AgentPad" : "New reply in a thread")
        badgeChanged()
    }

    // MARK: Taking back — by reconciling, not by differences (review F4-A)

    /// The ids of chat notices shown or pending; the system's outside tests.
    static var listIds: @MainActor () async -> [String] = {
        await AttentionCoordinator.shared.notificationManager?.chatIds() ?? []
    }
    private static var reconciling = false
    private static var reconcileAgain = false

    /// Takes back every chat notice that no longer applies: of another
    /// organization or account, signed out, rights in doubt, a snapshot
    /// owed, a channel not kept — or a message read, deleted or gone. Called
    /// on every change of what may be seen, and at start; calls meanwhile
    /// make one more pass.
    static func reconcile(_ service: ChatService = .shared) {
        service.reconcileChannelResults()
        guard !reconciling else { reconcileAgain = true; return }
        reconciling = true
        Task { @MainActor in
            repeat {
                reconcileAgain = false
                let ids = await listIds()
                let gone = ids.filter { !stillDue($0, service) }
                if !gone.isEmpty { remove(gone, nil) }
            } while reconcileAgain
            reconciling = false
            badgeChanged()
        }
    }

    /// Whether the notice `id` still applies now.
    static func stillDue(_ id: String, _ service: ChatService) -> Bool {
        let parts = id.split(separator: ":").map(String.init)
        guard parts.count == 4, parts[0] == "chat", let key = service.connection?.orgKey, key.orgId == parts[1],
              service.state == .signedIn else { return false }
        if parts[2] == "request" { return parts[3].hasSuffix("@\(key.accountId)") }
        let (channel, message) = (parts[2], parts[3])
        guard visible(service, key, channel), let store = service.orgSessions[key]?.store else { return false }
        if message.hasPrefix("request-") {
            guard let request = try? store.calls.request(String(message.dropFirst("request-".count))) else { return false }
            return request.kind == "channel" && request.channelId == channel && request.ownerAccountId == key.accountId
                && request.onThisDevice && request.state == .awaitingDecision
        }
        return (try? store.queue.read { db -> Bool in
            guard let row = try Row.fetchOne(db, sql: "SELECT deleted_at FROM messages WHERE message_id = ?", arguments: [message]),
                  (row["deleted_at"] as String?) == nil else { return false }
            return try Bool.fetchOne(db, sql: "SELECT read FROM notified WHERE object_id = ?", arguments: [message]) == false
        }) ?? false
    }
}
