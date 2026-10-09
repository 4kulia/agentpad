import AppKit
import Foundation
import ImageIO
import GRDB
import Observation

/// Shared by every window of one org. GRDB owns draft membership and versions;
/// owned originals survive pauses; transfers and previews obey the access gate.
@MainActor @Observable
final class ChatAttachmentManager {
    struct Stamp: Equatable, Hashable {
        var session: String
        var generation: String
        var access: Int
        var window: Int
        var connection: Int
        var channel: String
        var message: String?
        var revision: Int?
        var file: ChatAttachment?
        var executionAccess: Int
    }
    struct Preview: Identifiable {
        var stamp: Stamp
        var data: Data
        var id: String { stamp.file?.id ?? "" }
    }
    let key: ChatOrgKey
    let store: ChatStore
    let storage: ChatAttachmentStorage
    @ObservationIgnored weak var service: ChatService?
    private(set) var drafts: [ChatAttachmentDraft] = []
    private(set) var queued: [ChatAttachmentDraft] = []
    private(set) var revision = 0
    @ObservationIgnored private var watch: AnyDatabaseCancellable?
    @ObservationIgnored private var transfers: [String: (UUID, Task<Void, Never>)] = [:]
    @ObservationIgnored private var previews: [Stamp: Data] = [:]
    @ObservationIgnored private var decodedPreviews: [Stamp: CGImage] = [:]
    @ObservationIgnored private var previewCosts: [Stamp: Int] = [:]
    @ObservationIgnored private var lru: [Stamp] = []
    @ObservationIgnored private var reads: [UUID: (Stamp, Task<Data, Error>, [ChatAttachmentManifest]?)] = [:]
    @ObservationIgnored private var downloads = 0
    @ObservationIgnored private var activePreviews = 0
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var imports: [UUID: Task<Void, Never>] = [:]
    private(set) var importing: [UUID: (channel: String, root: String)] = [:]
    @ObservationIgnored private var thumbnails: [String: (Stamp, CGImage)] = [:]
    @ObservationIgnored private var thumbnailTasks: [String: (UUID, Task<Void, Never>)] = [:]
    @ObservationIgnored private var thumbnailAttempts: [String: Stamp] = [:]
    @ObservationIgnored var pollDelay: (Int) -> Duration = { .seconds(min(10, 2 + $0)) }

    init(service: ChatService, key: ChatOrgKey, store: ChatStore, storage: ChatAttachmentStorage) {
        self.service = service; self.key = key; self.store = store; self.storage = storage
        let changed = CoalescedMainActorAction { [weak self] in self?.reconcile() }
        watch = DatabaseRegionObservation(tracking: Table("meta"), Table("channels"), Table("teams"), Table("messages"),
            Table("requests"), Table("channel_call_intents"), Table("request_contents"), Table("attachment_drafts"), Table("attachment_deleted_sources"), Table("drafts"), Table("outbox"))
            .start(in: store.queue, onError: { _ in changed.schedule() }) { _ in changed.schedule() }
        // Recheck composer uploads after restart. Queued ready posts must replay
        // their exact payload first: publication may have lost its receipt.
        try? store.queue.write { db in
            for var draft in try ChatAttachments.drafts(db, includingQueued: true) where draft.state != .failed && !(draft.queued == true && draft.state == .ready) {
                draft.state = .waiting; draft.progress = 0; try ChatAttachments.put(db, draft)
            }
        }
        reconcile()
        expiry = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, self != nil else { return }
                self?.reconcile()
            }
        }
    }
    var limits: ChatAttachmentLimits? {
        guard let service, service.supports("chat.attachments", key: key),
              let limits = service.serverAttachmentLimits[key.server], limits.valid else { return nil }
        return limits
    }
    func stamp(channel: String, message: ChatMessage? = nil, file: ChatAttachment? = nil) -> Stamp? {
        _ = revision
        guard let service, limits != nil, service.orgSessions[key]?.store === store,
              service.isServerKnown(service, key), ChatNotifications.allowed(service, key, channel: channel), let connection = service.connection else { return nil }
        return try? store.queue.read { db -> Stamp? in
            guard let row = try Row.fetchOne(db, sql: "SELECT generation, pending_generation, channel_access_epoch FROM meta WHERE id = 1"),
                  let generation: String = row["generation"], (row["pending_generation"] as String?) == nil else { return nil }
            if let message, let file {
                guard let current = try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE message_id = ? AND channel_id = ?",
                    arguments: [message.id, channel]).map(ChatMessage.init(row:)), !current.deleted, !current.loading,
                      current.revision == message.revision, current.attachments.contains(file) else { return nil }
            }
            return Stamp(session: connection.sessionId, generation: generation, access: row["channel_access_epoch"],
                window: try ChatMessages.epoch(db, channel), connection: service.attachmentEpoch, channel: channel,
                message: message?.id, revision: message?.revision, file: file,
                executionAccess: try Int.fetchOne(db, sql: "SELECT version FROM attachment_access_versions WHERE channel_id = ?", arguments: [channel]) ?? -1)
        }
    }
    func current(_ capture: Stamp) -> Bool {
        var message: ChatMessage?
        if let id = capture.message {
            message = try? store.queue.read { try Row.fetchOne($0, sql: "SELECT * FROM messages WHERE message_id = ?", arguments: [id]).map(ChatMessage.init(row:)) }
            guard message != nil else { return false }
        }
        return stamp(channel: capture.channel, message: message, file: capture.file) == capture
    }
    func currentExecution(_ capture: Stamp, manifest: [ChatAttachmentManifest]) -> Bool {
        guard service?.supports("chat.attachments_context", key: key) == true,
              let now = stamp(channel: capture.channel), now.session == capture.session, now.generation == capture.generation,
              now.connection == capture.connection, now.executionAccess == capture.executionAccess, now.executionAccess >= 0 else { return false }
        return (try? store.queue.read { db in
            guard try Bool.fetchOne(db, sql: "SELECT archived FROM channels WHERE channel_id = ?", arguments: [capture.channel]) == false else { return false }
            let deleted = Set(try String.fetchAll(db, sql: "SELECT message_id FROM attachment_deleted_sources"))
            return !manifest.contains { deleted.contains($0.messageId) }
        }) == true
    }
    private func current(_ capture: Stamp, execution: [ChatAttachmentManifest]?) -> Bool {
        execution.map { currentExecution(capture, manifest: $0) } ?? current(capture)
    }
    func files(channel: String, root: String?) -> [ChatAttachmentDraft] {
        guard let service, ChatNotifications.allowed(service, key, channel: channel) else { return [] }
        return drafts.filter { $0.channel == channel && $0.root == (root ?? "") }
    }
    var pauseReason: String? { limits == nil ? ChatAttachmentError.paused.localizedDescription : nil }
    func suspend() {
        for task in imports.values { task.cancel() }; imports = [:]; importing = [:]
        for (_, task) in thumbnailTasks.values { task.cancel() }; thumbnailTasks = [:]
        thumbnails = [:]; thumbnailAttempts = [:]
        for (_, task) in transfers.values { task.cancel() }; transfers = [:]
        for (_, task, _) in reads.values { task.cancel() }; reads = [:]
        previews = [:]; decodedPreviews = [:]; previewCosts = [:]; lru = []; revision += 1
    }
    func revoke() {
        suspend()
        try? store.queue.write {
            try $0.execute(sql: "DELETE FROM attachment_drafts")
            try $0.execute(sql: "UPDATE drafts SET attachment_selection = '[]' WHERE attachment_selection != '[]'")
        }
        storage.prune(key, keeping: [])
        drafts = []; queued = []
        scrubConsents(revoked: true)
    }
    func reconcile() {
        defer { service?.reconcileAttachmentCalls(); scrubConsents() }
        guard let service else { suspend(); return }
        // Read errors and a server without file support are not revocations.
        guard let all = try? store.queue.write({ db in
            try ChatAttachments.reconcileOwnership(db)
        }) else { suspend(); return }
        var kept: [ChatAttachmentDraft] = []
        for var draft in all {
            let channel = try? store.queue.read { try Row.fetchOne($0, sql: "SELECT c.archived, t.mine FROM channels c JOIN teams t ON t.team_id = c.team_id WHERE c.channel_id = ?", arguments: [draft.channel]) }
            // A failed channel read is not a revocation. SQL also handles
            // revoke/rejoin before the observer gets a turn.
            if (channel?["mine"] as Bool?) == false, ChatNotifications.allowed(service, key, channel: nil) {
                remove(draft); continue
            }
            if draft.queued != true, draft.state != .failed {
                do {
                    if let capture = uploadStamp(channel: draft.channel) {
                        if draft.expiresAt <= Date() || draft.session != capture.session || draft.generation != capture.generation
                            || (draft.file.isImage && draft.sanitizedImageSHA256 != draft.sha256) {
                            let next = try renewed(draft, capture: capture)
                            try store.queue.write { try replace($0, draft: draft, with: next) }
                            storage.remove(key, id: draft.id)
                            draft = next
                        }
                    } else if draft.expiresAt <= Date() { throw ChatAttachmentError.expired }
                } catch {
                    draft.state = .failed; draft.problem = ChatAttachments.reason(error)
                    try? store.queue.write { try ChatAttachments.put($0, draft) }
                }
            }
            if transfers[draft.id] == nil, draft.state == .uploading || draft.state == .checking {
                draft.state = .waiting; try? store.queue.write { try ChatAttachments.put($0, draft) }
            }
            kept.append(draft)
        }
        let composing = kept.filter { $0.queued != true }, outgoing = kept.filter { $0.queued == true }
        if drafts != composing || queued != outgoing { drafts = composing; queued = outgoing; revision += 1 }
        storage.prune(key, keeping: Set(kept.map(\.id)))
        for (id, read) in reads where !current(read.0, execution: read.2) { read.1.cancel(); reads[id] = nil }
        for capture in Array(previews.keys) where !current(capture) { previews[capture] = nil; decodedPreviews[capture] = nil; previewCosts[capture] = nil; lru.removeAll { $0 == capture }; revision += 1 }
        if limits == nil || !ChatNotifications.allowed(service, key, channel: nil) { suspend(); return }
        for (id, cached) in thumbnails where !kept.contains(where: { $0.id == id }) || !current(cached.0) {
            thumbnails[id] = nil; thumbnailAttempts[id] = nil
        }
        for draft in composing where draft.file.isImage && thumbnailTasks[draft.id] == nil {
            guard let capture = stamp(channel: draft.channel), thumbnailAttempts[draft.id] != capture,
                  let limits, let url = try? storage.url(key, id: draft.id) else { continue }
            let attempt = UUID()
            thumbnailAttempts[draft.id] = capture
            thumbnailTasks[draft.id] = (attempt, Task { [weak self] in
                let image = try? await ChatAttachmentWorker.shared.thumbnail(at: url, limit: limits.fileBytes)
                guard let self, self.thumbnailTasks[draft.id]?.0 == attempt else { return }
                self.thumbnailTasks[draft.id] = nil
                guard !Task.isCancelled, self.current(capture), self.drafts.contains(where: { $0.id == draft.id }) else { self.reconcile(); return }
                if let image { self.thumbnails[draft.id] = (capture, image); self.revision += 1 }
            })
        }
        for (id, task) in transfers where !kept.contains(where: { $0.id == id && $0.state != .failed && uploadStamp(channel: $0.channel) != nil }) {
            task.1.cancel(); transfers[id] = nil
        }
        revision += 1
        pump()
        if service.attachmentManagers[key] === self { service.orgSessions[key]?.outbox?.pump() }
    }
    func add(urls: [URL], channel: String, root: String?) throws {
        for url in urls {
            guard let limits else { throw ChatAttachmentError.unavailable }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let bytes = try ChatAttachmentStorage.read(url, limit: limits.fileBytes)
            try add(data: bytes, name: url.lastPathComponent, channel: channel, root: root)
        }
    }
    func add(data: Data, name: String, channel: String, root: String?) throws {
        guard let limits, let capture = stamp(channel: channel), let service,
              service.isServerKnown(service, key),
              (try? store.queue.read { try Bool.fetchOne($0, sql: "SELECT archived FROM channels WHERE channel_id = ?", arguments: [channel]) }) == false else { throw ChatAttachmentError.unavailable }
        let (data, name) = try ChatAttachmentWorker.sanitizedFile(data, name: name, limits: limits)
        let file = try ChatAttachmentStorage.descriptor(data: data, name: name, limits: limits)
        try commit(data: data, file: file, digest: ChatAttachments.digest(data), thumbnail: nil, capture: capture, root: root)
    }
    /// Capture authorization before queueing work and recheck it on the actor
    /// before applying any bytes. Queued imports are bounded as well as decoding.
    func importFiles(_ inputs: [ChatAttachmentWorker.Input], channel: String, root: String?,
                     completion: @escaping @MainActor (Error?) -> Void = { _ in }) throws {
        try importFiles(count: inputs.count, channel: channel, root: root, load: { inputs }, completion: completion)
    }
    func importFiles(count: Int, channel: String, root: String?,
                     start: @MainActor () throws -> Void = {},
                     load: @escaping @MainActor () async throws -> [ChatAttachmentWorker.Input],
                     cleanup: @escaping @MainActor () -> Void = {},
                     completion: @escaping @MainActor (Error?) -> Void = { _ in }) throws {
        guard let limits, let capture = stamp(channel: channel) else { throw ChatAttachmentError.unavailable }
        guard count > 0, count <= limits.messageFiles, imports.count < min(8, limits.pendingFiles) else { throw ChatAttachmentError.size }
        do { try start() } catch { cleanup(); throw error }
        let id = UUID()
        importing[id] = (channel, root ?? "")
        imports[id] = Task { [weak self] in
            defer { cleanup() }
            guard let self else { return }
            defer { self.imports[id] = nil; self.importing[id] = nil }
            do {
                let inputs = try await load()
                guard !inputs.isEmpty, inputs.count <= limits.messageFiles else { throw ChatAttachmentError.size }
                guard !Task.isCancelled, self.current(capture), self.limits == limits else { throw ChatAttachmentError.unavailable }
                for input in inputs {
                    let prepared = try await ChatAttachmentWorker.shared.prepare(input, limits: limits)
                    guard !Task.isCancelled, self.current(capture), self.limits == limits else { throw ChatAttachmentError.unavailable }
                    try self.commit(data: prepared.data, file: prepared.file, digest: prepared.digest,
                        thumbnail: prepared.thumbnail, capture: capture, root: root)
                }
                completion(nil)
            } catch { completion(error) }
        }
    }
    func isImporting(channel: String, root: String?) -> Bool {
        importing.values.contains { $0.channel == channel && $0.root == (root ?? "") }
    }
    func draftImage(_ draft: ChatAttachmentDraft) -> CGImage? {
        _ = revision
        guard let cached = thumbnails[draft.id], current(cached.0), drafts.contains(where: { $0.id == draft.id }) else { return nil }
        return cached.1
    }
    private func commit(data: Data, file: ChatAttachment, digest: String, thumbnail: CGImage?, capture: Stamp, root: String?) throws {
        let channel = capture.channel
        guard current(capture), let limits,
              (try? store.queue.read { try Bool.fetchOne($0, sql: "SELECT archived FROM channels WHERE channel_id = ?", arguments: [channel]) }) == false else { throw ChatAttachmentError.unavailable }
        let all = try store.queue.read { try ChatAttachments.drafts($0, includingQueued: true) }
        let selected = all.filter { $0.queued != true && $0.channel == channel && $0.root == (root ?? "") }
        guard selected.count < limits.messageFiles, selected.reduce(data.count, { $0 + $1.file.size }) <= limits.messageBytes,
              all.count < limits.pendingFiles, all.reduce(data.count + limits.previewBytes, { $0 + $1.file.size + limits.previewBytes }) <= limits.pendingBytes else { throw ChatAttachmentError.size }
        var draft = ChatAttachmentDraft(file: file, messageId: selected.first?.messageId ?? UUID().uuidString.lowercased(),
            channel: channel, root: root ?? "", session: capture.session, generation: capture.generation,
            sha256: digest, createdAt: Date(), expiresAt: Date().addingTimeInterval(Double(limits.draftTTLSeconds)))
        if file.isImage { draft.sanitizedImageSHA256 = digest }
        try storage.save(data, key: key, id: file.id)
        do {
            try store.queue.write { db in
                try ChatAttachments.put(db, draft); try ChatAttachments.bumpDraft(db, channel: channel, root: root ?? "")
            }
        } catch { storage.remove(key, id: file.id); throw error }
        if let thumbnail { thumbnails[file.id] = (capture, thumbnail); thumbnailAttempts[file.id] = capture }
        reconcile()
    }
    func remove(_ draft: ChatAttachmentDraft, cancelOnServer: Bool = true) {
        // A composer in another window may still hold its pre-Send value.
        guard let owned = try? store.queue.read({ try ChatAttachments.drafts($0, includingQueued: true).first { $0.id == draft.id } }),
              (owned.queued == true) == (draft.queued == true) else { return }
        thumbnailTasks.removeValue(forKey: draft.id)?.1.cancel()
        thumbnails[draft.id] = nil; thumbnailAttempts[draft.id] = nil
        transfers.removeValue(forKey: draft.id)?.1.cancel()
        try? store.queue.write { db in
            try db.execute(sql: "DELETE FROM attachment_drafts WHERE attachment_id = ?", arguments: [draft.id])
            if draft.queued != true { try ChatAttachments.bumpDraft(db, channel: draft.channel, root: draft.root) }
        }
        storage.remove(key, id: draft.id)
        drafts.removeAll { $0.id == draft.id }; queued.removeAll { $0.id == draft.id }; revision += 1
        if cancelOnServer, limits != nil, let service, service.connection?.sessionId == draft.session, let token = service.token {
            let api = service.makeAPI(key.server), org = key.orgId, id = draft.id
            Task { try? await api.attachmentCommand(org: org, id: ChatUUID.v7(), type: "attachment.cancel", args: .object(["attachment_id": .string(id)]), token: token) }
        }
    }
    /// The execution journal keeps anti-replay facts, not retired file names/hashes.
    /// Finished calls retain their consent basis for result publication; unspent or
    /// revoked selections are voided, so erasure cannot create a weaker permission.
    func scrubConsents(revoked: Bool = false) {
        guard let journal = service?.journal else { return }
        let deleted = (try? store.queue.read { Set(try String.fetchAll($0, sql: "SELECT message_id FROM attachment_deleted_sources")) }) ?? []
        let retired = (try? store.queue.read { Set(try String.fetchAll($0, sql: "SELECT request_id FROM requests WHERE state IN ('finished','failed','failed_to_start','declined','cancelled','stopped','stop_failed','expired','stop_requested','lost')")) }) ?? []
        let channels = (try? store.queue.read { Set(try String.fetchAll($0, sql: "SELECT c.channel_id FROM channels c JOIN teams t ON t.team_id = c.team_id WHERE t.mine = 1")) }) ?? []
        try? store.queue.write { db in
            for id in retired {
                try db.execute(sql: "DELETE FROM request_contents WHERE request_id = ? AND json_array_length(content, '$.attachments') > 0", arguments: [id])
                try db.execute(sql: "UPDATE channel_call_intents SET attachment_manifest = '[]' WHERE request_id = ? AND attachment_manifest != '[]'", arguments: [id])
            }
            if revoked { try db.execute(sql: "UPDATE channel_call_intents SET attachment_manifest = '[]' WHERE attachment_manifest != '[]'") }
            else { try db.execute(sql: "UPDATE channel_call_intents SET attachment_manifest = '[]' WHERE attachment_manifest != '[]' AND message_id NOT IN (SELECT m.message_id FROM messages m JOIN channels c ON c.channel_id = m.channel_id JOIN teams t ON t.team_id = c.team_id WHERE t.mine = 1 AND m.deleted_at IS NULL)") }
        }
        try? journal.queue.write { db in
            let scope: StatementArguments = [key.server.description, key.accountId, key.orgId]
            for approval in try ChatApproval.fetchAll(db, sql: "SELECT * FROM approvals WHERE server = ? AND account_id = ? AND org_id = ?", arguments: scope) {
                guard var params = try? TeamLaunchParams.decode(approval.params), let files = params.inputs.attachments, !files.isEmpty else { continue }
                let lost = revoked || !channels.contains(params.channelId ?? "") || files.contains { deleted.contains($0.messageId) }
                guard lost || retired.contains(approval.requestId) else { continue }
                params.inputs.attachments = nil
                let data = try params.canonical()
                try db.execute(sql: "UPDATE approvals SET params = ?, params_hash = ? WHERE id = ?", arguments: [String(decoding: data, as: UTF8.self), TeamLaunchParams.hash(data), approval.id])
                if lost || approval.consumedAt == nil {
                    try db.execute(sql: "UPDATE approvals SET void_at = coalesce(void_at, ?), void_reason = coalesce(void_reason, 'attachment_revoked') WHERE id = ?", arguments: [Date(), approval.id])
                }
            }
            for row in try Row.fetchAll(db, sql: "SELECT id, body FROM channel_authorities WHERE server = ? AND account_id = ? AND org_id = ?", arguments: scope) {
                guard var authority = try? JSONDecoder().decode(ChatChannelAuthority.self, from: Data((row["body"] as String).utf8)), let files = authority.attachments, !files.isEmpty else { continue }
                let lost = revoked || !channels.contains(authority.channel) || files.contains { deleted.contains($0.messageId) }
                guard lost || retired.contains(authority.request ?? "") else { continue }
                authority.attachments = nil
                let json = String(decoding: try JSONEncoder().encode(authority), as: UTF8.self)
                try db.execute(sql: "UPDATE channel_authorities SET body = ?, revoked = MAX(revoked, ?) WHERE id = ?", arguments: [json, lost, row["id"] as String])
            }
        }
    }
    func uploadStamp(channel: String) -> Stamp? {
        guard (try? store.queue.read { try Bool.fetchOne($0, sql: "SELECT archived FROM channels WHERE channel_id = ?", arguments: [channel]) }) == false else { return nil }
        return stamp(channel: channel)
    }
    func canRetry(_ draft: ChatAttachmentDraft) -> Bool {
        draft.queued != true && draft.state == .failed && uploadStamp(channel: draft.channel) != nil
    }
    func retry(_ draft: ChatAttachmentDraft) {
        guard let current = try? store.queue.read({ try ChatAttachments.drafts($0).first { $0.id == draft.id } }),
              canRetry(current) else { return }
        var next = current; next.state = .waiting; next.problem = nil; next.progress = 0
        try? store.queue.write { try ChatAttachments.put($0, next) }
        reconcile()
    }
    private func pump() {
        guard let service, service.isServerKnown(service, key), let limits, let token = service.token else { return }
        for draft in drafts + queued where draft.state == .waiting && transfers[draft.id] == nil {
            guard transfers.count < min(2, limits.uploadsPerAccount), let capture = uploadStamp(channel: draft.channel) else { continue }
            let attempt = UUID(), api = service.makeAPI(key.server)
            transfers[draft.id] = (attempt, Task { [weak self] in
                guard let self else { return }
                defer { if self.transfers[draft.id]?.0 == attempt { self.transfers[draft.id] = nil; self.reconcile() } }
                @MainActor func update(_ change: (inout ChatAttachmentDraft) -> Void) throws {
                    guard !Task.isCancelled, self.current(capture), self.transfers[draft.id]?.0 == attempt,
                          var row = try self.store.queue.read({ try ChatAttachments.drafts($0, includingQueued: true).first { $0.id == draft.id } }),
                          row.state != .failed else { throw CancellationError() }
                    change(&row)
                    try self.store.queue.write { try ChatAttachments.put($0, row) }
                    if let index = self.drafts.firstIndex(where: { $0.id == row.id }) { self.drafts[index] = row }
                }
                do {
                    try update { $0.state = .uploading; $0.problem = nil }
                    let data = try ChatAttachmentStorage.read(self.storage.url(self.key, id: draft.id), limit: limits.fileBytes)
                    guard data.count == draft.file.size, ChatAttachments.digest(data) == draft.sha256 else { throw ChatAttachmentError.hash }
                    // Composer drafts are sanitized into a fresh reservation by
                    // reconcile. Never mutate an unanswered queued post's IDs.
                    guard !draft.file.isImage || draft.sanitizedImageSHA256 == draft.sha256 else { throw ChatAttachmentError.changed }
                    try await api.attachmentCommand(org: self.key.orgId, id: draft.prepareCommand, type: "attachment.prepare", args: draft.prepareArgs, token: token)
                    try update { _ in }
                    var metadata = try await api.attachmentMetadata(org: self.key.orgId, id: draft.id, token: token)
                    if ["reserved", "uploading"].contains(metadata.state) {
                        try await api.attachmentUpload(org: self.key.orgId, id: draft.id, data: data, token: token, seconds: limits.uploadRequestSeconds) { [weak self] value in
                            Task { @MainActor in
                                guard let self, self.current(capture), self.transfers[draft.id]?.0 == attempt,
                                      let index = self.drafts.firstIndex(where: { $0.id == draft.id }) else { return }
                                self.drafts[index].progress = value
                            }
                        }
                    }
                    try update { $0.state = .checking; $0.progress = 1 }
                    try await api.attachmentCommand(org: self.key.orgId, id: draft.completeCommand, type: "attachment.complete", args: .object(["attachment_id": .string(draft.id)]), token: token)
                    var poll = 0
                    while true {
                        try update { _ in }
                        metadata = try await api.attachmentMetadata(org: self.key.orgId, id: draft.id, token: token)
                        guard metadata.attachmentId == draft.id else { throw ChatAttachmentError.unavailable }
                        guard Date() < draft.expiresAt else { throw ChatAPIError.server(status: 409, code: "attachment_expired", retryAfter: nil) }
                        if metadata.state == "ready" {
                            guard metadata.size == draft.file.size, let name = metadata.name, let mime = metadata.mime,
                                  limits.mimeTypes.contains(mime) else { throw ChatAttachmentError.hash }
                            try update {
                                $0.state = .ready; $0.file.name = name; $0.file.mime = mime
                                $0.file.hasPreview = metadata.hasPreview == true; $0.file.width = metadata.width; $0.file.height = metadata.height
                                if let expires = metadata.expiresAt.flatMap(ChatStore.date) { $0.expiresAt = min($0.expiresAt, expires) }
                            }
                            break
                        }
                        if metadata.state == "deleted" { throw ChatAPIError.server(status: 400, code: metadata.error ?? "invalid_file", retryAfter: nil) }
                        try await Task.sleep(for: self.pollDelay(poll)); poll += 1
                    }
                } catch is CancellationError { }
                catch {
                    try? update {
                        $0.state = .failed; $0.problem = ChatAttachments.reason(error)
                        if (error as? ChatAPIError)?.code == "attachment_expired" { $0.expiresAt = .distantPast }
                    }
                    service.attachmentAccessFailed(error, key: self.key, store: self.store, session: capture.session)
                }
            })
        }
    }
    /// Called synchronously before the send transaction. No caption-only fallback.
    func prepared(channel: String, root: String?) throws -> [ChatAttachmentDraft] {
        guard !isImporting(channel: channel, root: root) else { throw ChatAttachmentError.changed }
        let files = try store.queue.read { try ChatAttachments.drafts($0, channel: channel, root: root) }
        guard !files.isEmpty else { return [] }
        guard limits != nil else { throw ChatAttachmentError.paused }
        guard let limits, let capture = stamp(channel: channel), files.count <= limits.messageFiles,
              files.reduce(0, { $0 + $1.file.size }) <= limits.messageBytes,
              files.allSatisfy({ $0.state == .ready && $0.expiresAt > Date() && $0.session == capture.session && $0.generation == capture.generation }) else { throw ChatAttachmentError.changed }
        return files
    }
    func image(_ message: ChatMessage, file: ChatAttachment) -> CGImage? {
        _ = revision
        guard let capture = stamp(channel: message.channelId, message: message, file: file), let image = decodedPreviews[capture] else { return nil }
        lru.removeAll { $0 == capture }; lru.append(capture)
        return image
    }
    func load(_ message: ChatMessage, file: ChatAttachment, preview: Bool) async throws -> Data {
        guard let capture = stamp(channel: message.channelId, message: message, file: file), let limits else { throw ChatAttachmentError.unavailable }
        if preview, let cached = previews[capture] { return cached }
        let data: Data
        do {
            data = try await transfer(capture, path: "/v1/orgs/\(key.orgId)/attachments/\(file.id)/\(preview ? "preview" : "original")",
                limit: preview ? limits.previewBytes : min(file.size, limits.fileBytes), preview: preview)
        } catch {
            previews[capture] = nil; decodedPreviews[capture] = nil; previewCosts[capture] = nil; revision += 1
            throw error
        }
        if preview {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0, w <= limits.previewSide, h <= limits.previewSide, w <= (16 * 1024 * 1024) / h,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ChatAttachmentError.type }
            let cost = data.count + w * h * 4
            guard cost <= 64 * 1024 * 1024 else { throw ChatAttachmentError.size }
            while previewCosts.values.reduce(0, +) + cost > 64 * 1024 * 1024, let oldest = lru.first {
                lru.removeFirst(); previews[oldest] = nil; decodedPreviews[oldest] = nil; previewCosts[oldest] = nil
            }
            previews[capture] = data; decodedPreviews[capture] = image; previewCosts[capture] = cost
            lru.append(capture); revision += 1
        } else if data.count != file.size { throw ChatAttachmentError.hash }
        return data
    }
    /// Both viewer downloads and execution copies share cancellation and limits.
    /// The directory of an in-flight call is already registered for revocation.
    func transfer(_ capture: Stamp, path: String, limit: Int, preview: Bool = false, execution: [ChatAttachmentManifest]? = nil) async throws -> Data {
        guard current(capture, execution: execution), let service, let token = service.token, let limits else { throw ChatAttachmentError.unavailable }
        while downloads >= min(4, limits.downloadsPerAccount) || (preview && activePreviews >= 2) {
            try await Task.sleep(for: .milliseconds(50)); guard current(capture, execution: execution) else { throw ChatAttachmentError.unavailable }
        }
        downloads += 1; if preview { activePreviews += 1 }
        defer { downloads -= 1; if preview { activePreviews -= 1 } }
        let data: Data
        do {
            let api = service.makeAPI(key.server)
            let id = UUID()
            let task = Task { try await api.attachmentBytes(path: path, token: token, limit: limit) }
            reads[id] = (capture, task, execution)
            defer { reads[id] = nil }
            data = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            service.attachmentAccessFailed(error, key: key, store: store, session: capture.session)
            throw error
        }
        guard !Task.isCancelled, current(capture, execution: execution) else { throw ChatAttachmentError.unavailable }
        return data
    }
    func save(_ message: ChatMessage, file: ChatAttachment, window: NSWindow, stillValid: @MainActor () -> Bool) async throws {
        guard let capture = stamp(channel: message.channelId, message: message, file: file) else { throw ChatAttachmentError.unavailable }
        let panel = NSSavePanel(); panel.nameFieldStringValue = file.name
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url, current(capture), stillValid() else { return }
        let data = try await load(message, file: file, preview: false)
        guard current(capture), stillValid() else { throw ChatAttachmentError.unavailable }
        try data.write(to: url, options: .atomic)
    }
}

extension ChatService {
    /// Metadata, bytes and both manifest reads share the same access boundary.
    /// A late response from an old session/cache cannot close its replacement.
    func attachmentAccessFailed(_ error: Error, key: ChatOrgKey, store: ChatStore, session: String) {
        guard connection?.sessionId == session, connection?.server == key.server, connection?.accountId == key.accountId,
              let current = orgSessions[key], current.store === store,
              case .server(let status, _, _) = error as? ChatAPIError else { return }
        switch status {
        case 401: sessionEnded("Sign in again.")
        case 403, 404:
            if let sync = current.sync { sync.rightsInDoubt() }
            else {
                do { try store.putRightsInDoubt() }
                catch { current.doubtNotWritten = true; current.doubtWriteFailures += 1 }
            }
            attachmentManagers[key]?.suspend()
            reconcileAttachmentCalls()
            if status == 404 { accountFeed?.readMeAgain() }
        default: break
        }
    }

    func attachments(_ key: ChatOrgKey) -> ChatAttachmentManager? {
        guard let store = orgSessions[key]?.store else { return nil }
        if let kept = attachmentManagers[key], kept.store === store { return kept }
        attachmentManagers[key]?.suspend()
        let made = ChatAttachmentManager(service: self, key: key, store: store, storage: files.attachmentStorage)
        attachmentManagers[key] = made
        return made
    }
    func invalidateAttachments() {
        attachmentEpoch += 1
        mcpDownloads.removeAll()
        for manager in attachmentManagers.values { manager.suspend() }
        for files in attachmentCalls.values { files.remove() }; attachmentCalls = [:]
    }
}
