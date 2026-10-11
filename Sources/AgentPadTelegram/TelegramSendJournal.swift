import CryptoKit
import Foundation

/// Actor-confined, local-only metadata journal. Text/reply/file drafts live in
/// a separately encrypted vault, never in the chat index or server outbox.
final class TelegramSendJournal {
    struct Part: Codable, Equatable {
        enum State: String, Codable {
            case queued, submitting, pending, sent, failed, unknown, restored
            var canRestore: Bool { self == .queued || self == .failed }
        }
        var key: UUID = UUID()
        var sendingID: Int64 = Int64.random(in: 1...Int64(Int32.max))
        var messageID: Int64?
        var previousID: Int64?
        var state: State = .queued
        var attachment: UUID?
    }
    struct Operation: Codable {
        var id: UUID
        var chat: Int64
        var topic: TelegramMessageTopic?
        var botStart: Int64?
        var keyboardRevision: UUID?
        var revision: UUID
        var created: Date
        var parts: [Part]
    }
    private let directory: URL
    private let key: SymmetricKey
    private(set) var operations: [Operation] = []
    private struct Recovery: Codable { let operation: Operation; var draft: TelegramDraft }
    private var recovery: [UUID: Recovery] = [:]
    private var draftAttachments: [String: Set<UUID>] = [:]
    private struct Staged: Codable { let file: TelegramStagedAttachment; let digest: Data }
    private var staged: [UUID: Staged] = [:]
    let staging: URL
    private(set) var cacheLimitMiB = 512

    init(directory: URL, databaseKey: Data, now: Date) throws {
        self.directory = directory.appendingPathComponent("conversation", isDirectory: true)
        staging = self.directory.appendingPathComponent("staging", isDirectory: true)
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: databaseKey), salt: Data("AgentPad Telegram drafts v1".utf8), info: Data(), outputByteCount: 32)
        try TelegramProfileStore.createDirectory(self.directory)
        try TelegramProfileStore.createDirectory(staging)
        if let data = try read("cache-limit.json", limit: 1024) {
            let saved = try JSONDecoder().decode(Int.self, from: data)
            if [128, 256, 512, 1024].contains(saved) { cacheLimitMiB = saved }
        }
        if let data = try read("staged.json", limit: 128 * 1024) { staged = try JSONDecoder().decode([UUID: Staged].self, from: data) }
        if let data = try read("operations.json", limit: 4 * 1024 * 1024) {
            operations = try JSONDecoder().decode([Operation].self, from: data)
            guard operations.count <= 4096 else { throw TelegramConversationError.storage }
        }
        if let data = try read("recovery.enc", limit: 2 * 1024 * 1024) {
            recovery = try JSONDecoder().decode([UUID: Recovery].self, from: decrypt(data))
            guard recovery.count <= 10 else { throw TelegramConversationError.storage }
        }
        for url in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            if name.hasPrefix("draft-"), name.hasSuffix(".enc"), let data = try read(name, limit: 128 * 1024) {
                let draft = try JSONDecoder().decode(TelegramDraft.self, from: decrypt(data))
                draftAttachments[name] = Set(draft.attachments.map(\.id))
            }
            if name.hasPrefix("import-") { removeImportDirectory(url) }
        }
        // The vault is committed before metadata. Recover the bounded intent if
        // the process stopped between those writes; never replay it.
        for (id, saved) in recovery where !operations.contains(where: { $0.id == id }) { operations.append(saved.operation) }
        guard operations.count <= 4096 else { throw TelegramConversationError.storage }
        for i in operations.indices {
            for j in operations[i].parts.indices where operations[i].parts[j].state == .submitting {
                // Never infer delivery or replay after a lost result.
                operations[i].parts[j].state = .unknown
            }
        }
        operations.removeAll { op in
            // Keep the identity of an unresolved recovery until its explicit
            // review/discard, otherwise the ten-version vault becomes orphaned.
            recovery[op.id] == nil && now.timeIntervalSince(op.created) > 7 * 86400 && op.parts.allSatisfy { ![.submitting, .pending].contains($0.state) }
        }
        try save()
        // A crash can leave files behind between any two durable writes. Only
        // drafts and unresolved recovery own staging across launches.
        for operation in operations { try pruneRecovery(operation) }
        try sweepStaging()
    }
    private func read(_ name: String, limit: Int) throws -> Data? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try TelegramProfileStore.validate(url, directory: false)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw TelegramConversationError.storage }
        return data
    }
    private func decrypt(_ data: Data) throws -> Data { try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key) }
    private func encrypt(_ data: Data) throws -> Data { try AES.GCM.seal(data, using: key).combined! }
    private func draftName(chat: Int64, topic: TelegramMessageTopic?) throws -> String {
        guard topic == nil || topic?.forumID != nil else { throw TelegramConversationError.unavailable }
        return "draft-\(chat)" + (topic?.forumID.map { "-forum-\($0)" } ?? "") + ".enc"
    }
    func draft(chat: Int64, topic: TelegramMessageTopic? = nil) throws -> TelegramDraft {
        guard let data = try read(draftName(chat: chat, topic: topic), limit: 128 * 1024) else { return TelegramDraft() }
        return try JSONDecoder().decode(TelegramDraft.self, from: decrypt(data))
    }
    func saveDraft(_ draft: TelegramDraft, chat: Int64, topic: TelegramMessageTopic? = nil) throws {
        guard draft.text.utf8.count <= 64 * 1024, draft.attachments.count <= 10 else { throw TelegramConversationError.files }
        let name = try draftName(chat: chat, topic: topic)
        try TelegramProfileStore.write(encrypt(JSONEncoder().encode(draft)), to: directory.appendingPathComponent(name))
        let previous = draftAttachments[name] ?? []
        draftAttachments[name] = Set(draft.attachments.map(\.id))
        for id in previous.subtracting(draftAttachments[name]!) { removeStage(id) }
    }
    func create(chat: Int64, topic: TelegramMessageTopic? = nil, botStart: Int64? = nil, keyboardRevision: UUID? = nil, draft: TelegramDraft, parts: [Part], now: Date) throws -> UUID {
        guard !operations.contains(where: { $0.chat == chat && $0.topic == topic && $0.revision == draft.revision }) else { throw TelegramConversationError.unavailable }
        guard operations.count < 4096, recovery.count < 10 else { throw TelegramConversationError.recovery }
        let id = UUID()
        let operation = Operation(id: id, chat: chat, topic: topic, botStart: botStart, keyboardRevision: keyboardRevision, revision: draft.revision, created: now, parts: parts)
        // Recovery is durable before intent; a crash between the two is safe.
        recovery[id] = Recovery(operation: operation, draft: draft)
        do { try saveRecovery() } catch { recovery[id] = nil; throw error }
        operations.append(operation)
        try save()
        return id
    }
    func update(_ id: UUID, _ change: (inout Operation) -> Void) throws {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { throw TelegramConversationError.unavailable }
        let previous = operations[index]
        change(&operations[index])
        do { try save() } catch { operations[index] = previous; throw error }
        try pruneRecovery(operations[index])
    }
    func operation(_ id: UUID) -> Operation? { operations.first { $0.id == id } }
    func recovered(_ id: UUID) -> TelegramDraft? { recovery[id]?.draft }
    func removeRecovery(_ id: UUID) throws {
        let previous = recovery.removeValue(forKey: id)
        do { try saveRecovery() } catch { recovery[id] = previous; throw error }
        for file in previous?.draft.attachments ?? [] { removeStage(file.id) }
    }
    private func pruneRecovery(_ operation: Operation) throws {
        guard var saved = recovery[operation.id] else { return }
        let unresolved = operation.parts.filter { ![.sent, .restored].contains($0.state) }
        guard !unresolved.isEmpty else { try removeRecovery(operation.id); return }
        let previous = saved
        let retained = Set(unresolved.compactMap(\.attachment))
        saved.draft.attachments.removeAll { !retained.contains($0.id) }
        if let first = operation.parts.first, [.sent, .restored].contains(first.state) { saved.draft.text = "" }
        guard saved.draft != previous.draft else { return }
        recovery[operation.id] = saved
        do { try saveRecovery() } catch { recovery[operation.id] = previous; throw error }
        for file in previous.draft.attachments where !retained.contains(file.id) { removeStage(file.id) }
    }
    func restore(_ id: UUID) throws -> TelegramDraft {
        guard let operation = operation(id), var draft = recovered(id),
              operation.parts.contains(where: { $0.state.canRestore }), try self.draft(chat: operation.chat, topic: operation.topic).isEmpty else {
            throw TelegramConversationError.unavailable
        }
        let restored = Set(operation.parts.filter { $0.state.canRestore }.compactMap(\.attachment))
        draft.attachments.removeAll { !restored.contains($0.id) }
        if operation.parts.first?.state.canRestore != true { draft.text = "" }
        draft.revision = UUID()
        // Transfer ownership to the composer before releasing recovery's files.
        try saveDraft(draft, chat: operation.chat, topic: operation.topic)
        try update(id) { operation in
            for index in operation.parts.indices where operation.parts[index].state.canRestore { operation.parts[index].state = .restored }
        }
        return draft
    }
    private func save() throws {
        let bytes = try JSONEncoder().encode(operations)
        guard bytes.count <= 4 * 1024 * 1024 else { throw TelegramConversationError.storage }
        try TelegramProfileStore.write(bytes, to: directory.appendingPathComponent("operations.json"))
    }
    private func saveRecovery() throws {
        try TelegramProfileStore.write(encrypt(JSONEncoder().encode(recovery)), to: directory.appendingPathComponent("recovery.enc"))
    }
    func stage(_ data: Data, name: String, mime: String, width: Int, height: Int) throws -> TelegramStagedAttachment {
        let bytes = staged.values.reduce(0) { $0 + $1.file.size }
        guard data.count > 0, data.count <= TelegramFeedLimits.fileBytes, staged.count < 20,
              bytes + data.count <= TelegramFeedLimits.stagedBytes,
              !name.isEmpty, name.utf8.count <= 200, !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              ["image/png", "image/jpeg", "application/pdf", "text/plain", "application/json"].contains(mime) else { throw TelegramConversationError.files }
        let file = TelegramStagedAttachment(id: UUID(), name: name, mime: mime, size: data.count, width: width, height: height)
        try TelegramProfileStore.createDirectory(staging.appendingPathComponent(file.id.uuidString))
        staged[file.id] = Staged(file: file, digest: Data(SHA256.hash(data: data)))
        try TelegramProfileStore.write(data, to: stageURL(file.id))
        try saveStages()
        return file
    }
    func stageURL(_ id: UUID) -> URL { staging.appendingPathComponent(id.uuidString).appendingPathComponent(staged[id]?.file.name ?? "unavailable") }
    func validate(_ file: TelegramStagedAttachment) throws {
        let url = stageURL(file.id)
        try TelegramProfileStore.validate(url, directory: false)
        guard let staged = staged[file.id], staged.file == file, try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == file.size,
              file.size <= TelegramFeedLimits.fileBytes, Data(SHA256.hash(data: try Data(contentsOf: url))) == staged.digest else { throw TelegramConversationError.files }
    }
    func removeStage(_ id: UUID) {
        guard !ownsStage(id) else { return }
        try? FileManager.default.removeItem(at: staging.appendingPathComponent(id.uuidString))
        staged[id] = nil; try? saveStages()
    }
    private func ownsStage(_ id: UUID) -> Bool {
        draftAttachments.values.contains { $0.contains(id) }
            || recovery.values.contains { $0.draft.attachments.contains { $0.id == id } }
    }
    private func sweepStaging() throws {
        for id in staged.keys where !ownsStage(id) { staged[id] = nil }
        for url in try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            if let id = UUID(uuidString: url.lastPathComponent), !ownsStage(id) { try FileManager.default.removeItem(at: url) }
        }
        try saveStages()
    }
    private func saveStages() throws { try TelegramProfileStore.write(JSONEncoder().encode(staged), to: directory.appendingPathComponent("staged.json")) }
    func importDirectory() throws -> URL {
        let url = directory.appendingPathComponent("import-" + UUID().uuidString, isDirectory: true)
        try TelegramProfileStore.createDirectory(url)
        return url
    }
    func setCacheLimit(_ limit: Int) throws {
        guard [128, 256, 512, 1024].contains(limit) else { throw TelegramConversationError.unavailable }
        try TelegramProfileStore.write(JSONEncoder().encode(limit), to: directory.appendingPathComponent("cache-limit.json"))
        cacheLimitMiB = limit
    }
    func removeImportDirectory(_ url: URL) {
        guard url.deletingLastPathComponent() == directory, url.lastPathComponent.hasPrefix("import-"),
              UUID(uuidString: String(url.lastPathComponent.dropFirst(7))) != nil else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
