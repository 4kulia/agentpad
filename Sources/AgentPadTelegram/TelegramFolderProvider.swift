import Foundation

// Older fixtures and disconnected providers need no folder implementation.
// Writes fail explicitly rather than silently succeeding.
public extension TelegramChatProvider {
    func chatPage(list: TelegramListKey, from: Int, revision: UInt64, binding: TelegramProfileBinding) async -> TelegramChatPage { .init(revision: revision, offset: from, rows: []) }
    func expandChats(list: TelegramListKey, showLess: Bool, binding: TelegramProfileBinding) async throws { throw TelegramFolderError.unavailable }
    func holdChatOrder(list: TelegramListKey, held: Bool, owner: UUID, binding: TelegramProfileBinding) async throws { throw TelegramFolderError.unavailable }
    func attentionPage(start: Int, revision: UInt64, binding: TelegramProfileBinding) async -> TelegramChatPage { .init(revision: revision, offset: start, rows: []) }
    func holdAttentionOrder(_ held: Bool, owner: UUID, binding: TelegramProfileBinding) async throws { throw TelegramFolderError.unavailable }
    func setViewport(list: TelegramListKey, windows: Set<Int>, binding: TelegramProfileBinding) async throws { throw TelegramFolderError.unavailable }
    func setListVisible(_ list: TelegramListKey, visible: Bool, binding: TelegramProfileBinding) async throws { throw TelegramFolderError.unavailable }
    func setListCollapsed(window: UUID, list: TelegramListKey, collapsed: Bool, binding: TelegramProfileBinding) async throws { throw TelegramFolderError.unavailable }
    func retainFolderWindows(_ windows: Set<UUID>, binding: TelegramProfileBinding) async throws { throw TelegramFolderError.unavailable }
    func customMembers(binding: TelegramProfileBinding) async throws -> [UUID:Set<Int64>] { throw TelegramFolderError.unavailable }
    func customSummaries(binding: TelegramProfileBinding) async throws -> [TelegramFolderSummary] { [] }
    func setCustomMember(folder: UUID, chat: Int64, member: Bool, binding: TelegramProfileBinding) async throws { throw TelegramFolderError.unavailable }
    func applyTombstones(_ tombstones: Set<UUID>, binding: TelegramProfileBinding) async throws { throw TelegramFolderError.unavailable }
    func markAsRead(_ chat: Int64, retry: Set<TelegramMarkReadStep>?, binding: TelegramProfileBinding) async -> TelegramMarkReadResult {
        var result = TelegramMarkReadResult(); result.error = .unavailable; return result
    }
    func setFollow(_ chat: Int64, enabled: Bool, binding: TelegramProfileBinding) async throws { throw TelegramFolderError.unavailable }
}
