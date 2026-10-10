import AppKit
import Observation

/// One account or owned publication operation, separate from the chat outbox.
/// An ambiguous write keeps its exact command and bytes until checked.
@MainActor @Observable
final class ChatAvatarEditor {
    enum Recovery: Equatable { case retry, reload, choose, smaller, connect }
    enum Operation: Equatable {
        case idle, loading, saving, checking, saved, unsupported
        case failed(String, Recovery)
    }
    let reference: ChatAvatarReference
    let service: ChatService
    var profileRevision: Int?
    var source: CGImage?
    var crop = AvatarCrop()
    private(set) var operation: Operation = .idle
    private(set) var inFlight = false
    private(set) var confirmed: ChatAvatarMetadata?
    private(set) var command: ChatAvatarCommand?
    private(set) var retryAt: Date?
    @ObservationIgnored var onConfirmed: (ChatAvatarMetadata) throws -> Void = { _ in }
    private var boundContext: ChatAvatarContext?
    private var unrecorded: ChatAvatarMetadata?
    var needsCheck: Bool { command != nil || unrecorded != nil }
    private var prepared: Data?
    private var removing = false
    private var active = true
    private var editEpoch = 0
    var blocksEditing: Bool { inFlight || needsCheck }
    var canRetry: Bool { !inFlight && (retryAt ?? .distantPast) <= Date() }

    init(reference: ChatAvatarReference, service: ChatService = .shared) { self.reference = reference; self.service = service }
    private func authorization() -> ChatAvatarAuthorization? {
        guard active else { return nil }
        guard service.state == .signedIn, service.connection?.orgKey == reference.key else {
            operation = .failed("Connect a team to update this photo.", .connect); return nil
        }
        guard service.supports("chat.avatars", key: reference.key) else { operation = .unsupported; return nil }
        guard let auth = service.avatarWriteAuthorization(reference) else {
            operation = .failed("Waiting for current team access. Reload when connected.", .reload); return nil
        }
        return auth
    }
    private func current(_ context: ChatAvatarContext, epoch: Int) -> Bool {
        guard active, editEpoch == epoch else { return false }
        guard service.avatarWriteAuthorization(reference)?.context == context else {
            command = nil; unrecorded = nil; prepared = nil; source = nil; confirmed = nil
            operation = .failed("The connection changed. Reload, then confirm your photo again.", .reload)
            return false
        }
        return true
    }
    func load() async {
        guard active, !inFlight, let auth = authorization() else { return }
        if needsCheck {
            if boundContext != auth.context {
                command = nil; unrecorded = nil; confirmed = nil
                operation = .failed("The connection changed. Reload, then confirm your photo again.", .reload)
            } else if command != nil { operation = .checking }
            return
        }
        let epoch = editEpoch
        inFlight = true; operation = .loading
        defer { inFlight = false }
        do {
            let reply = try await auth.api.avatarMetadata(reference.subject, key: reference.key, generation: auth.context.generation, token: auth.token)
            guard current(auth.context, epoch: epoch) else { return }
            service.avatars.receive(reply.avatar, for: reference, context: auth.context)
            confirmed = service.avatars.metadata[reference.subject]; boundContext = auth.context
            operation = .idle
        } catch {
            guard current(auth.context, epoch: epoch) else { return }
            fail(error, context: auth.context, writing: false)
        }
    }
    func choose(_ url: URL) async {
        guard active, !blocksEditing else { return }
        editEpoch += 1; let epoch = editEpoch
        inFlight = true; operation = .loading
        let result = await Task.detached(priority: .userInitiated) { Result { try LocalAvatarImage.read(url) } }.value
        inFlight = false
        guard active, editEpoch == epoch else { return }
        switch result {
        case .success(let pixels): source = pixels; crop = .init(); prepared = nil; removing = false; operation = .idle
        case .failure(let error): operation = .failed(error.localizedDescription, .choose)
        }
    }
    func preparationFailed(_ error: Error) {
        guard active else { return }
        operation = .failed(error.localizedDescription, .choose)
    }
    func capabilityAvailable() {
        guard active, operation == .unsupported, !inFlight else { return }
        operation = .failed("Profile photos are now supported. Retry to publish your saved photo.", .retry)
    }
    func cancelCrop() {
        guard active, !blocksEditing else { return }
        source = nil; prepared = nil; removing = false; operation = .idle; editEpoch += 1
    }
    func invalidate() { active = false; editEpoch += 1; source = nil; prepared = nil; command = nil; unrecorded = nil }
    func saveCrop() async {
        if case .failed(_, .reload) = operation { return }
        guard active, !blocksEditing, let source, let auth = authorization() else { return }
        let epoch = editEpoch, crop = crop
        inFlight = true; operation = .saving
        let result = await Task.detached(priority: .userInitiated) { Result { try ChatAvatarImage.prepare(source, crop: crop, limits: auth.limits) } }.value
        inFlight = false
        guard current(auth.context, epoch: epoch) else { return }
        switch result {
        case .success(let data): await save(data)
        case .failure(let error): operation = .failed(error.localizedDescription, .choose)
        }
    }
    func remove() async { await save(nil) }
    /// Prepared local agent images enter the same CAS/error/replay lane.
    func save(_ data: Data?) async {
        if case .failed(_, .reload) = operation { return }
        guard active, !blocksEditing, let auth = authorization() else { return }
        if confirmed == nil { await load() }
        guard let confirmed, !inFlight, let currentAuth = authorization(), currentAuth.context == auth.context,
              boundContext == auth.context else {
            if active { operation = .failed("Reload the current photo before saving.", .reload) }
            return
        }
        prepared = data; removing = data == nil; retryAt = nil
        command = .init(expectedRevision: confirmed.revision, generation: auth.context.generation, data: data)
        await send(auth, automaticallyCheck: true)
    }
    func retry() async {
        guard operation == .checking || { if case .failed(_, .retry) = operation { return true }; return false }() else { return }
        guard active, canRetry, let auth = authorization() else { return }
        if let unrecorded {
            guard boundContext == auth.context, service.avatars.metadata[reference.subject] == unrecorded else {
                self.unrecorded = nil; operation = .failed("This photo changed. Reload before another change.", .reload); return
            }
            do { try record(unrecorded) }
            catch { operation = .failed("The photo was saved, but its local confirmation could not be saved. Retry.", .retry) }
            return
        }
        if command != nil {
            guard boundContext == auth.context, command?.generation == auth.context.generation else {
                command = nil; operation = .failed("The server changed. Reload, then confirm your photo again.", .reload); return
            }
            await send(auth, automaticallyCheck: false)
        } else if prepared != nil || removing { await save(prepared) }
        else if source != nil { await saveCrop() }
        else { await load() }
    }
    func smaller() async {
        guard active, canRetry, command == nil, let prepared, let auth = authorization() else { return }
        do {
            let pixels = try ChatAvatarImage.read(prepared)
            let bytes = try ChatAvatarImage.prepare(pixels, limits: auth.limits, maxSide: max(1, pixels.width * 3 / 4))
            await save(bytes)
        } catch { operation = .failed(error.localizedDescription, .choose) }
    }
    private func send(_ auth: ChatAvatarAuthorization, automaticallyCheck: Bool) async {
        guard let command else { return }
        let epoch = editEpoch
        inFlight = true; operation = automaticallyCheck ? .saving : .checking
        defer { inFlight = false }
        do {
            let reply = try await auth.api.avatarWrite(reference.subject, key: reference.key, command: command, token: auth.token)
            guard current(auth.context, epoch: epoch), self.command == command else { return }
            service.avatars.receive(reply.avatar, for: reference, context: auth.context)
            confirmed = reply.avatar; self.command = nil
            guard service.avatars.metadata[reference.subject] == reply.avatar, reply.avatar.revision == reply.appliedRevision,
                  (reply.avatar.imageId == nil) == (command.data == nil) else {
                operation = .failed("This photo changed elsewhere after saving. Reload before another change.", .reload); return
            }
            unrecorded = reply.avatar
            try record(reply.avatar)
        } catch {
            guard current(auth.context, epoch: epoch) else { return }
            fail(error, context: auth.context, writing: true)
            if operation == .checking, automaticallyCheck {
                // One immediate replay, then a visible Check again action. No
                // background queue and no new command after a lost response.
                await send(auth, automaticallyCheck: false)
            }
        }
    }
    private func record(_ avatar: ChatAvatarMetadata) throws {
        try onConfirmed(avatar)
        unrecorded = nil; source = nil; prepared = nil; removing = false; operation = .saved
    }
    private func fail(_ error: Error, context: ChatAvatarContext, writing: Bool) {
        if case ChatAPIError.server(let status, let code, let retry) = error {
            if writing, command != nil, status == 408 || (500..<600).contains(status) {
                // A gateway or server can fail after committing the write.
                // Verify it with the original command, just like a lost reply.
                operation = .checking
                return
            }
            command = nil
            switch (status, code) {
            case (401, _):
                service.sessionEnded("Sign in again.")
                operation = .failed("Sign in again to update your photo.", .connect)
            case (_, "unsupported"): operation = .unsupported
            case (413, _): operation = .failed("The server needs a smaller image. Reduce it and try again.", .smaller)
            case (_, "revision_conflict"): confirmed = nil; operation = .failed("This photo changed elsewhere. Reload before saving.", .reload)
            case (_, "generation_mismatch"), (_, "command_expired"), (_, "command_conflict"):
                confirmed = nil; operation = .failed("The server changed. Reload, then confirm your photo again.", .reload)
            case (404, _), (403, _): operation = .failed("This photo is no longer available with your current access. Reload.", .reload)
            case (_, "invalid_file"), (415, _): operation = .failed("Choose another still JPG or PNG image.", .choose)
            case (429, _):
                retryAt = Date().addingTimeInterval(max(1, retry ?? 60))
                operation = .failed("Too many photo changes. Wait before retrying.", .retry)
            case (_, "storage_quota_exceeded"): operation = .failed("The organization's photo storage is full. Try a smaller image.", .smaller)
            default: operation = .failed("Couldn’t save the photo. Try again when the server is available.", .retry)
            }
        } else if writing, command != nil {
            operation = .checking
        } else { operation = .failed(error.localizedDescription, .retry) }
    }
}
