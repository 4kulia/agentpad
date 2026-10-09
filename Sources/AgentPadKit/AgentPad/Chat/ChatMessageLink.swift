import AppKit

/// A locator only: no message text, account credentials or execution arguments.
struct ChatMessageLink: Equatable {
    var server: ChatServerAddress
    var org: String
    var channel: String
    var message: String
    var sequence: Int

    init(key: ChatOrgKey, message: ChatMessage) {
        server = key.server; org = key.orgId; channel = message.channelId
        self.message = message.messageId; sequence = message.seq ?? 0
    }

    init(key: ChatOrgKey, channel: String, message: String, sequence: Int) {
        server = key.server; org = key.orgId; self.channel = channel; self.message = message; self.sequence = sequence
    }

    init?(components: URLComponents) {
        let items = components.queryItems ?? []
        guard components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
              components.path.isEmpty || (components.host?.isEmpty != false && components.path == "/chat"),
              items.count == 5, Set(items.map(\.name)) == Set(["server", "org", "channel", "message", "seq"]) else { return nil }
        func value(_ key: String) -> String { items.first { $0.name == key }?.value ?? "" }
        guard let server = try? ChatServerAddress(parsing: value("server")),
              UUID(uuidString: value("org")) != nil, UUID(uuidString: value("channel")) != nil,
              UUID(uuidString: value("message")) != nil, let seq = Int(value("seq")), seq > 0, seq < Int.max else { return nil }
        self.server = server; org = value("org").lowercased(); channel = value("channel").lowercased()
        message = value("message").lowercased(); sequence = seq
    }

    var url: URL? {
        guard !channel.isEmpty else { return nil }
        var parts = URLComponents()
        parts.scheme = AgentPadDeepLink.scheme; parts.host = "chat"
        parts.queryItems = [URLQueryItem(name: "server", value: server.description), URLQueryItem(name: "org", value: org),
                            URLQueryItem(name: "channel", value: channel), URLQueryItem(name: "message", value: message),
                            URLQueryItem(name: "seq", value: String(sequence))]
        return parts.url
    }

    func matches(key: ChatOrgKey, channel: String) -> Bool { server == key.server && org == key.orgId && self.channel == channel }
}

extension Notification.Name { static let chatMessageNavigation = Notification.Name("AgentPad.chatMessageNavigation") }

@MainActor
enum ChatMessageNavigation {
    private final class Request {
        let key: ChatOrgKey
        let link: ChatMessageLink
        weak var destination: NSView?
        init(key: ChatOrgKey, link: ChatMessageLink, destination: NSView) {
            self.key = key; self.link = link; self.destination = destination
        }
    }
    private static var pending: Request?
    static func request(_ link: ChatMessageLink, key: ChatOrgKey, destination: NSView) {
        pending = Request(key: key, link: link, destination: destination)
        NotificationCenter.default.post(name: .chatMessageNavigation, object: nil)
    }
    /// The selected tab may still be detached while AppKit mounts it. Target
    /// its host, not the key window or another tab of the same channel.
    static func take(key: ChatOrgKey, channel: String, from view: NSView?) -> ChatMessageLink? {
        guard let request = pending else { return nil }
        guard let destination = request.destination else { pending = nil; return nil }
        guard request.key == key, request.link.matches(key: key, channel: channel),
              let view, view === destination || view.isDescendant(of: destination) else { return nil }
        pending = nil
        return request.link
    }
}
