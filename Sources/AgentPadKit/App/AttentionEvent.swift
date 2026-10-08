import CryptoKit
import Foundation

/// Metadata only. Channel contents and execution permissions stay in their sources.
struct AttentionScope: Codable, Hashable, Sendable {
    var server: String
    var account: String
    var organization: String
    var generation: String
}

enum AttentionCategory: String, CaseIterable, Codable, Sendable {
    case decisions, attention, completion, failure, publication, mentions, replies, account, updates, program

    var label: String {
        switch self {
        case .decisions: return "Approvals, access and confirmations"
        case .attention: return "Agent needs input"
        case .completion: return "Successful runs"
        case .failure: return "Failures, stops and recovery"
        case .publication: return "Answers published or sent"
        case .mentions: return "Mentions of me"
        case .replies: return "Replies in my threads"
        case .account: return "Sign-in, access and devices"
        case .updates: return "App updates"
        case .program: return "Terminal program notifications"
        }
    }
}

enum AttentionKind: String, Codable, Sendable {
    case decision, version, folder, publicationReview, input, recovery, signIn
    case completion, failure, stopped, publication, mention, reply, account, update, updateFailure, updateInstalled, confirmation, program

    var category: AttentionCategory {
        switch self {
        case .decision, .version, .folder, .publicationReview, .confirmation: return .decisions
        case .input: return .attention
        case .recovery, .failure, .stopped: return .failure
        case .signIn, .account: return .account
        case .completion: return .completion
        case .publication: return .publication
        case .mention: return .mentions
        case .reply: return .replies
        case .update, .updateFailure, .updateInstalled: return .updates
        case .program: return .program
        }
    }
    var needsDecision: Bool {
        switch self {
        case .decision, .version, .folder, .publicationReview, .input, .recovery, .signIn, .update, .confirmation: return true
        default: return false
        }
    }
    /// Sources of the same message share an ID; upgrading never sounds twice.
    var priority: Int { needsDecision ? 100 : self == .mention ? 30 : self == .reply ? 20 : 10 }
    var title: String {
        switch self {
        case .decision: return "A request waits for your decision"
        case .version: return "A Claude Code version needs approval"
        case .folder: return "A folder request waits for your decision"
        case .publicationReview: return "An answer is ready for publication review"
        case .input: return "An agent needs your input"
        case .recovery: return "A problem needs your attention"
        case .signIn: return "Sign in to continue"
        case .completion: return "A run finished"
        case .failure: return "A run or operation failed"
        case .stopped: return "A run was stopped or declined"
        case .publication: return "An agent answer was published"
        case .mention: return "New mention in AgentPad"
        case .reply: return "New reply in a thread"
        case .account: return "Your account or access changed"
        case .update: return "An AgentPad update is available"
        case .updateFailure: return "An AgentPad update operation failed"
        case .updateInstalled: return "AgentPad was updated"
        case .confirmation: return "A confirmation waits for your decision"
        case .program: return "A terminal program sent a notification"
        }
    }
}

enum AttentionOrganizationSection: String, Codable, Hashable, Sendable {
    case members, teams, invitations, devices, audit
}

enum AttentionDestination: Codable, Hashable, Sendable {
    case terminal(UUID)
    case external(String)
    case team(request: String?, outgoing: Bool)
    case version(UUID)
    case folder(String, request: String)
    case channel(String, request: String)
    case message(channel: String, message: String, thread: String?, sequence: Int)
    case organization(String, section: AttentionOrganizationSection? = nil)
    case connect
    case recovery(String?)
    case update(String)
    case sheet(UUID)
    case tabAction(tabID: TabID, actionID: UUID)
    case linkFailure(windowID: UUID)
    // Reserved until these have real client sources.
    case invitation(String), directMessage(String), publicationProposal(String)
}

struct AttentionEvent: Identifiable, Equatable, Codable, Sendable {
    let id: String
    var source: String
    var kind: AttentionKind
    var destination: AttentionDestination
    var scope: AttentionScope?
    var timestamp: Date
    var isRead = false
    var actionInFlight = false
    var suppressesDelivery = false
    /// Only local terminals may supply display text. Never persisted.
    var localTitle: String?
    var localBody: String?

    init(source: String, object: String, episode: String = "", kind: AttentionKind,
         destination: AttentionDestination, scope: AttentionScope? = nil, timestamp: Date = Date()) {
        self.source = source; self.kind = kind; self.destination = destination
        self.scope = scope; self.timestamp = timestamp
        id = Self.identifier([scope?.server ?? "", scope?.account ?? "", scope?.organization ?? "",
                              scope?.generation ?? "", source, object, episode])
    }
    static func identifier(_ components: [String]) -> String {
        let bytes = (try? JSONEncoder().encode(components)) ?? Data()
        return "attention:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    enum CodingKeys: String, CodingKey {
        case id, source, kind, destination, scope, timestamp, isRead, actionInFlight, suppressesDelivery
    }
    var title: String { source == "link-failure" ? "Link could not be opened" : scope == nil ? (localTitle ?? kind.title) : kind.title }
    var body: String { scope == nil ? (localBody ?? "") : "" }
}

struct AttentionPreferences: Equatable, Sendable {
    var enabled = true
    var sound = true
    var disabled: Set<AttentionCategory> = []
    static func read(_ values: [String: Any]) -> Self {
        Self(enabled: values["enabled"] as? Bool ?? true, sound: values["sound"] as? Bool ?? true,
             disabled: Set(AttentionCategory.allCases.filter { values[$0.rawValue] as? Bool == false }))
    }
    func persisted(over values: [String: Any]) -> [String: Any] {
        var result = values
        result["enabled"] = enabled ? nil : false
        result["sound"] = sound ? nil : false
        for category in AttentionCategory.allCases { result[category.rawValue] = disabled.contains(category) ? false : nil }
        return result
    }
}

enum AttentionPolicy {
    static func shouldDeliver(_ event: AttentionEvent, preferences: AttentionPreferences, focused: Bool, live: Bool = true) -> Bool {
        guard preferences.enabled, !preferences.disabled.contains(event.kind.category), !event.actionInFlight, !event.suppressesDelivery else { return false }
        return event.kind.needsDecision || (live && !event.isRead && !focused)
    }
}

/// Durable metadata, never a second source of requests, commands or message text.
@MainActor
final class NotificationDeliveryStore {
    struct Marker: Codable { var delivered = false; var read = false; var consumed = false; var hidden = false; var locator: AttentionEvent? }
    private let defaults: UserDefaults?
    private let key = "AgentPad.notificationMetadata.v1"
    private(set) var markers: [String: Marker]
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        markers = defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Marker].self, from: $0) } ?? [:]
    }
    func update(_ id: String, _ change: (inout Marker) -> Void) {
        var value = markers[id] ?? Marker(); change(&value); markers[id] = value
        if markers.count > 2000 {
            let obsolete = markers.filter { $0.value.locator?.kind.needsDecision != true }
                .sorted { ($0.value.locator?.timestamp ?? .distantPast) < ($1.value.locator?.timestamp ?? .distantPast) }
            for entry in obsolete.prefix(markers.count - 2000) { markers[entry.key] = nil }
        }
        if let data = try? JSONEncoder().encode(markers) { defaults?.set(data, forKey: key) }
    }
}

@MainActor @Observable
final class AttentionLedger {
    static let shared = AttentionLedger(metadata: NotificationDeliveryStore(defaults: .standard))
    private(set) var events: [AttentionEvent] = []
    @ObservationIgnored let metadata: NotificationDeliveryStore
    @ObservationIgnored var delivery: NotificationManager?
    @ObservationIgnored var preferences: () -> AttentionPreferences = { AttentionPreferences() }
    @ObservationIgnored var isFocused: (AttentionEvent) -> Bool = { _ in false }
    @ObservationIgnored var isValid: (AttentionEvent) -> Bool = { _ in true }
    @ObservationIgnored var onChange: () -> Void = {}
    init(metadata: NotificationDeliveryStore = NotificationDeliveryStore()) { self.metadata = metadata }

    var pendingCount: Int { events.filter { $0.kind.needsDecision }.count }
    var unreadCount: Int { events.filter { !$0.isRead }.count }

    private static func newestFirst(_ lhs: AttentionEvent, _ rhs: AttentionEvent) -> Bool {
        lhs.timestamp == rhs.timestamp ? lhs.id < rhs.id : lhs.timestamp > rhs.timestamp
    }

    /// Choose the whole history window before scheduling any asynchronous
    /// delivery. A newest-first source may contain far more than 100 outcomes.
    func upsert(_ snapshot: [AttentionEvent], live: (AttentionEvent) -> Bool) {
        var candidates: [String: AttentionEvent] = [:]
        for event in events + snapshot where !event.kind.needsDecision && isValid(event) {
            if candidates[event.id] == nil { candidates[event.id] = event }
        }
        let history = Set(candidates.values.sorted(by: Self.newestFirst).prefix(100).map(\.id))
        for event in snapshot where event.kind.needsDecision || history.contains(event.id) {
            upsert(event, live: live(event))
        }
    }

    func upsert(_ event: AttentionEvent, live: Bool = true) {
        guard isValid(event) else { resolve(event.id); return }
        if !event.kind.needsDecision && metadata.markers[event.id]?.hidden == true { return }
        var next = event
        let focused = isFocused(next)
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            let old = events[index]
            guard old.kind.priority <= event.kind.priority else { return }
            next.timestamp = old.timestamp; next.isRead = old.isRead || event.isRead || focused
            if next == old { return }
            events[index] = next
        } else {
            if !event.kind.needsDecision {
                let history = events.filter { !$0.kind.needsDecision }.sorted(by: Self.newestFirst)
                if history.count >= 100, let oldest = history.last, !Self.newestFirst(event, oldest) { return }
            }
            next.isRead = event.isRead || metadata.markers[event.id]?.read == true || focused || (!live && !event.kind.needsDecision)
            events.append(next)
            events.sort(by: Self.newestFirst)
            // History is bounded; a live decision is never dropped to make room.
            var history = 0
            events.removeAll { item in
                guard !item.kind.needsDecision else { return false }
                history += 1; return history > 100
            }
        }
        if !live && !event.kind.needsDecision { metadata.update(event.id) { $0.consumed = true } }
        if next.isRead { metadata.update(event.id) { $0.read = true } }
        if case .tabAction = next.destination { /* runtime-only consent */ }
        else { metadata.update(next.id) { $0.locator = next } }
        deliver(next.id)
        if !next.kind.needsDecision { metadata.update(next.id) { $0.consumed = true } }
        onChange()
    }

    func deliver(_ id: String) {
        guard let event = events.first(where: { $0.id == id }) else { return }
        if event.isRead && !event.kind.needsDecision { delivery?.remove(ids: [id]); return }
        let marker = metadata.markers[id]
        guard marker?.delivered != true, event.kind.needsDecision || marker?.consumed != true,
              AttentionPolicy.shouldDeliver(event, preferences: preferences(), focused: isFocused(event)) else { return }
        delivery?.upsert(event, sound: preferences().sound, isCurrent: { [weak self] in
            guard let self, let now = self.events.first(where: { $0.id == id }), self.isValid(now) else { return false }
            return AttentionPolicy.shouldDeliver(now, preferences: self.preferences(), focused: self.isFocused(now))
        }, didDeliver: { [weak self] in self?.metadata.update(id) { $0.delivered = true } })
    }

    func settingsChanged() {
        for event in events {
            if !AttentionPolicy.shouldDeliver(event, preferences: preferences(), focused: isFocused(event)) { delivery?.remove(ids: [event.id]) }
            else if event.kind.needsDecision { deliver(event.id) }
        }
    }
    func event(_ id: String) -> AttentionEvent? {
        events.first { $0.id == id } ?? metadata.markers[id]?.locator
    }
    func resolve(_ id: String) {
        delivery?.remove(ids: [id])
        let existed = events.contains { $0.id == id }
        events.removeAll { $0.id == id }
        if metadata.markers[id]?.locator != nil { metadata.update(id) { $0.locator = nil } }
        if existed { onChange() }
    }
    func reconcile(source: String, keeping ids: Set<String>) {
        // On restart, delivered/pending decisions exist only in metadata until
        // their sources have been projected. Missing waits are resolved too.
        let known = events + metadata.markers.values.compactMap(\.locator)
        let obsolete = Set(known.filter { $0.source == source && !ids.contains($0.id) }.map(\.id))
        for id in obsolete { resolve(id) }
    }
    func validateAll() {
        for event in events where !isValid(event) { resolve(event.id) }
        for event in events where isFocused(event) { markRead(event.id) }
    }
    func markRead(_ id: String) {
        guard let index = events.firstIndex(where: { $0.id == id }), !events[index].isRead else { return }
        events[index].isRead = true; metadata.update(id) { $0.read = true }
        if !events[index].kind.needsDecision { delivery?.remove(ids: [id]) }
        onChange()
    }
    func markAllRead() { for event in events { markRead(event.id) } }
    func clearHistory() {
        for event in events where !event.kind.needsDecision {
            metadata.update(event.id) { $0.hidden = true }
            resolve(event.id)
        }
    }
}
