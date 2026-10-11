import AgentPadTelegram
import Foundation
import Observation

@Observable @MainActor
final class TelegramSearchModel {
    let chats: TelegramChatsModel
    private(set) var value = TelegramSearchSnapshot(query: "")
    private(set) var opening = false
    var hits: [TelegramSearchHit] { value.hits }
    @ObservationIgnored var changed: () -> Void = {}
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var lastAccount: TelegramChatID?
    @ObservationIgnored private var lastQuery: String?
    @ObservationIgnored private var openingGeneration: UUID?
    init(chats: TelegramChatsModel) { self.chats = chats; chats.registerSearch(self) }
    deinit { task?.cancel() }
    func search(_ query: String, force: Bool = false) {
        guard force || lastQuery != query || lastAccount != chats.snapshot.account else { return }
        task?.cancel(); generation = UUID(); let generation = generation
        opening = false; openingGeneration = nil
        lastAccount = chats.snapshot.account; lastQuery = query
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Available synchronously, before any actor hop / TDLib response.
        let instant = chats.snapshot.automaticRows.filter {
            normalized.isEmpty || $0.title.localizedCaseInsensitiveContains(normalized) || $0.username.localizedCaseInsensitiveContains(normalized.trimmingCharacters(in: CharacterSet(charactersIn: "@")))
        }.map { TelegramSearchHit(row: $0) }
        value = .init(query: query, hits: instant, searching: chats.connected, notice: chats.connected ? nil : "Connect Telegram…")
        changed()
        guard let provider = chats.provider else { return }
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let stream = await provider.searchTelegram(query)
            for await value in stream {
                guard !Task.isCancelled, let self, self.generation == generation,
                      self.lastAccount == self.chats.snapshot.account else { return }
                self.value = value; self.changed()
            }
        }
    }
    func cancelOpening() { opening = false; openingGeneration = nil }
    func stop() {
        task?.cancel(); task = nil; generation = UUID(); lastQuery = nil
        cancelOpening(); value.searching = false
    }
    func accountChanged() {
        stop(); lastAccount = chats.snapshot.account
        value = .init(query: value.query, notice: chats.connected ? nil : "Connect Telegram…")
        changed()
    }
    func open(_ hit: TelegramSearchHit, from store: WorkspaceStore, beside: Bool, pin: Bool) async -> Bool {
        guard !opening, let provider = chats.provider else { return false }
        let operation = UUID(); openingGeneration = operation; opening = true
        defer { if openingGeneration == operation { opening = false; openingGeneration = nil } }
        let account = chats.snapshot.account
        let resolved = await provider.resolveChat(hit)
        guard openingGeneration == operation, !Task.isCancelled, chats.snapshot.account == account else { return false }
        guard let row = resolved else {
            value.notice = "This Telegram chat could not be opened. Try again when connected."; return false
        }
        guard TelegramTabs.open(row, from: store, beside: beside) != nil else { return false }
        await provider.didOpenChat(row.id)
        if pin, row.kind.eligible { await provider.setChatMode(row.id, mode: .pinned) }
        return true
    }
}
