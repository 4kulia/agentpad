import AgentPadTelegram
import Foundation

/// A bounded adapter for TDLib's transport snapshot. It uses the existing
/// Attention delivery/navigation; the sidebar projection owns all marks.
@MainActor
final class TelegramNotifications {
    static let shared = TelegramNotifications()
    var manager: NotificationManager?
    var preferences: () -> AttentionPreferences = { AgentPadSettingsModel.shared.notificationPreferences }
    var isFocused: (TelegramChatID) -> Bool = { AttentionFocus.focused(.telegram($0.root, message: 0)) }
    var open: (TelegramAttentionSummary) -> Bool = { TelegramTabs.openAttention($0, from: nil) }
    private(set) var current: [String: TelegramNotification] = [:]
    private var binding: TelegramChatID?
    private var generation = UUID()
    private var prepared = false
    private(set) var initialized = false
    private var suppressed = Set<String>()
    private var reconcileTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var provider: (any TelegramChatProvider)?
    var categoryTimeout: Duration = .seconds(5)
    private var categoryDeadlines: [String: ContinuousClock.Instant] = [:]
    private var categoryTask: Task<Void, Never>?

    func receive(_ snapshot: TelegramChatSnapshot, provider: (any TelegramChatProvider)?) {
        self.provider = provider
        if binding != snapshot.account {
            generation = UUID(); binding = snapshot.account; prepared = false; initialized = false
            manager?.remove(ids: Array(current.keys)); current = [:]; suppressed = []
            reconcileTask?.cancel(); reconcileTask = nil
            clearCategoryWait()
        }
        let transport = snapshot.attention.notifications
        guard snapshot.account != nil, transport.initialized else {
            if snapshot.state == .disconnected {
                manager?.remove(ids: Array(current.keys)); current = [:]; clearCategoryWait()
            }
            return
        }
        let next = Dictionary(transport.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        manager?.remove(ids: current.keys.filter { next[$0] == nil })
        current = next; suppressed.formIntersection(Set(next.keys))
        // Both maps are bounded by TDLib's active notification snapshot. One
        // timer wakes delivery without holding up already classified notices.
        categoryDeadlines = categoryDeadlines.filter { next[$0.key]?.categoryPending == true }
        for item in next.values where item.categoryPending && item.mayDeliver && categoryDeadlines[item.id] == nil {
            categoryDeadlines[item.id] = .now.advanced(by: categoryTimeout)
        }
        scheduleCategoryTimeout()
        initialized = true
        AttentionCoordinator.shared.navigation?.retryPending()
        if !prepared, reconcileTask == nil, manager != nil {
            let generation = generation
            reconcileTask = Task { [weak self] in
                guard let self, let manager = self.manager else { return }
                let delivered = await manager.identifiers()
                guard !Task.isCancelled, self.generation == generation else { return }
                manager.remove(ids: delivered.filter { $0.hasPrefix("telegram:") && self.current[$0] == nil })
                self.prepared = true; self.reconcileTask = nil
                self.deliver(provider: provider)
            }
        } else if prepared { deliver(provider: provider) }
    }
    func disconnect() {
        generation = UUID(); let epoch = generation
        current = [:]; binding = nil; suppressed = []; initialized = true; prepared = false
        reconcileTask?.cancel(); reconcileTask = nil
        clearCategoryWait()
        Task { [weak self] in
            guard let self, let manager = self.manager else { return }
            let ids = await manager.identifiers()
            guard self.generation == epoch else { return }
            manager.remove(ids: ids.filter { $0.hasPrefix("telegram:") })
        }
    }
    func settingsChanged(provider: (any TelegramChatProvider)?) {
        for item in current.values where deliveryItem(item) != nil && !allowed(item) {
            manager?.remove(ids: [item.id]); suppressed.insert(item.id)
        }
        deliver(provider: provider)
    }
    private func clearCategoryWait() {
        categoryDeadlines = [:]; categoryTask?.cancel(); categoryTask = nil
    }
    private func scheduleCategoryTimeout() {
        categoryTask?.cancel(); categoryTask = nil
        guard let deadline = categoryDeadlines.values.filter({ $0 > .now }).min() else { return }
        let epoch = generation
        categoryTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard let self, !Task.isCancelled, self.generation == epoch else { return }
            self.categoryTask = nil
            self.deliver(provider: self.provider)
            self.scheduleCategoryTimeout()
        }
    }
    private func deliveryItem(_ item: TelegramNotification) -> TelegramNotification? {
        guard item.categoryPending else { return item }
        guard let deadline = categoryDeadlines[item.id], deadline <= .now else { return nil }
        // A stalled lookup must not lose a possible reply when mentions are
        // disabled. Use either enabled category after the bounded wait.
        var resolved = item
        resolved.kind = preferences().disabled.contains(.mentions) ? .reply : .mention
        resolved.categoryPending = false
        return resolved
    }
    private func allowed(_ item: TelegramNotification) -> Bool {
        guard let item = deliveryItem(item) else { return false }
        let category: AttentionCategory = switch item.kind {
        case .direct, .channelPost, .groupMessage: .dm
        case .mention: .mentions
        case .reply, .botReply: .replies
        }
        guard !item.viewed, !isFocused(item.destination) else { return false }
        let settings = preferences()
        return settings.enabled && !settings.disabled.contains(category)
    }
    private func deliver(provider: (any TelegramChatProvider)?) {
        guard let manager, prepared, deliveryTask == nil else { return }
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            // One worker awaits OS delivery; incoming snapshots replace the
            // bounded map instead of adding tasks behind a permission prompt.
            while self.prepared, let item = self.current.values.sorted(by: { $0.date < $1.date }).first(where: {
                $0.mayDeliver && !self.suppressed.contains($0.id) && self.deliveryItem($0) != nil
            }) {
                self.suppressed.insert(item.id)
                let epoch = self.generation
                guard await self.provider?.consumeNotification(item.id) == true,
                      self.generation == epoch, let current = self.current[item.id],
                      let resolved = self.deliveryItem(current), self.allowed(resolved) else { continue }
                manager.upsert(self.event(resolved), sound: resolved.sound && self.preferences().sound,
                    isCurrent: { [weak self] in
                        guard let self, self.generation == epoch, let now = self.current[item.id] else { return false }
                        return self.allowed(now)
                    })
                await manager.drain(id: item.id)
            }
            self.deliveryTask = nil
        }
    }
    func activate(_ id: String) -> Bool {
        guard let item = current[id], item.destination.root.account == binding?.account,
              item.destination.environment == binding?.environment else { return false }
        let summary = TelegramAttentionSummary(destination: item.destination, count: item.count, firstMessage: item.message,
            lastDate: item.date, kind: item.kind, identity: id)
        // Navigation does not acknowledge a Telegram read. The visible feed
        // calls viewMessages and only TDLib updates clear the source reason.
        return open(summary)
    }
    func event(_ item: TelegramNotification) -> AttentionEvent {
        var event = AttentionEvent(source: "telegram", object: item.id,
            kind: item.kind == .mention ? .mention : item.kind == .reply || item.kind == .botReply ? .reply : .dm,
            destination: .telegram(item.destination, message: item.message), timestamp: Date(timeIntervalSince1970: Double(item.date)), id: item.id)
        event.localTitle = "Telegram"
        event.localBody = "New message · \(item.count) addressed \(item.count == 1 ? "message" : "messages")"
        return event
    }
}
