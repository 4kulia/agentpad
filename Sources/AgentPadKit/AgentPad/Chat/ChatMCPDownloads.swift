import Darwin
import Foundation
import GRDB

extension ChatFiles {
    var mcpDownloadsRoot: URL {
        directory == Self.standard.directory
            ? AgentPadShellIntegration.agentPadAppSupport("mcp-downloads", isDirectory: true)
            : directory.appendingPathComponent("mcp-downloads", isDirectory: true)
    }
}

extension ChatAttachment {
    var mcpDescriptor: ChatJSON { .object(["attachment_id": .string(id), "name": .string(name), "mime": .string(mime), "size": .number(Double(size))]) }
}

extension ChatSessionTools {
    static func attachmentProjection(_ messages: [ChatMessageWire]) throws -> ChatJSON {
        .array(try messages.map { message in
            guard case .object(var fields) = try JSONDecoder().decode(ChatJSON.self, from: JSONEncoder().encode(message)) else { throw Failure(code: "not_found") }
            fields["attachments"] = .array(message.deletedAt == nil ? message.attachments.map(\.mcpDescriptor) : [])
            return .object(fields)
        })
    }

    /// One wall-clock budget covers identity/page lookup and binary transfer.
    /// The IPC cancellation also cancels URLSession; no half-file survives.
    static func withDownloadDeadline(seconds: TimeInterval, isCallerWaiting: @escaping @MainActor () -> Bool,
                                     operation: @escaping @MainActor () async throws -> ChatJSON) async throws -> ChatJSON {
        try await withThrowingTaskGroup(of: ChatJSON.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                let end = ContinuousClock.now + .milliseconds(Int64(seconds * 1000))
                while ContinuousClock.now < end {
                    guard await isCallerWaiting() else { throw CancellationError() }
                    try await Task.sleep(for: min(.milliseconds(100), ContinuousClock.now.duration(to: end)))
                }
                throw Failure(code: "download_timeout")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// Originals downloaded for personal MCP callers. Separate from drafts and
/// executor manifests; each reservation owns a random directory and filename.
@MainActor
final class ChatMCPDownloads {
    struct Reservation {
        var id: String
        var file: ChatAttachment
        var surface: String
        var key: ChatOrgKey
        var path: URL
        var expires: Date
    }
    let root: URL
    var quota = 100 * 1024 * 1024
    var now: () -> Date = Date.init
    static let ttl: TimeInterval = 24 * 60 * 60
    private var entries: [String: Reservation] = [:]
    private var watches: [ChatOrgKey: AnyDatabaseCancellable] = [:]
    private var stamps: [ChatOrgKey: String] = [:]
    private var expiry: Task<Void, Never>?

    init(root: URL) {
        self.root = root
        // No paths from the previous app lifetime are still owned by a tab.
        removeAll()
    }
    deinit { expiry?.cancel() }

    private func rootFD(create: Bool) throws -> Int32 {
        guard !TeamStorage.isTestProcess || TeamStorage.testDirectoryIsSafe(root) else { throw ChatSessionTools.Failure(code: "download_unavailable") }
        if create {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ChatSessionTools.Failure(code: "download_unavailable") }
        guard fchmod(fd, 0o700) == 0 else { close(fd); throw ChatSessionTools.Failure(code: "download_unavailable") }
        return fd
    }

    func reserve(_ file: ChatAttachment, surface: String, key: ChatOrgKey, store: ChatStore) throws -> Reservation {
        cleanup()
        guard file.size > 0, file.size <= quota,
              entries.values.reduce(0, { $0 + $1.file.size }) <= quota - file.size else { throw ChatSessionTools.Failure(code: "download_limit") }
        let fd = try rootFD(create: true); defer { close(fd) }
        let id = UUID().uuidString.lowercased()
        guard mkdirat(fd, id, 0o700) == 0 else { throw ChatSessionTools.Failure(code: "download_unavailable") }
        // The remote filename is display metadata only, never a path component.
        let ext = ["image/png": "png", "image/jpeg": "jpg", "application/pdf": "pdf", "text/plain": "txt",
                   "text/markdown": "md", "application/json": "json"][file.mime] ?? "bin"
        let path = root.appendingPathComponent(id).appendingPathComponent(UUID().uuidString.lowercased() + "." + ext)
        let reservation = Reservation(id: id, file: file, surface: surface, key: key, path: path, expires: now().addingTimeInterval(Self.ttl))
        entries[id] = reservation
        watch(key, store: store)
        if expiry == nil {
            expiry = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard let self else { return }
                    self.cleanup()
                }
            }
        }
        return reservation
    }

    func finish(_ reservation: Reservation, bytes: Data) throws -> ChatJSON {
        guard entries[reservation.id] != nil, now() < reservation.expires, !Task.isCancelled,
              bytes.count == reservation.file.size else { throw ChatSessionTools.Failure(code: "download_unavailable") }
        let fd = try rootFD(create: false); defer { close(fd) }
        let folder = openat(fd, reservation.id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw ChatSessionTools.Failure(code: "download_unavailable") }
        defer { close(folder) }
        let name = reservation.path.lastPathComponent
        let output = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw ChatSessionTools.Failure(code: "download_unavailable") }
        var complete = false
        defer { close(output); if !complete { unlinkat(folder, name, 0) } }
        try bytes.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ChatSessionTools.Failure(code: "download_unavailable") }
                offset += count
            }
        }
        guard fchmod(folder, 0o700) == 0, fchmod(output, 0o600) == 0, fsync(output) == 0 else { throw ChatSessionTools.Failure(code: "download_unavailable") }
        var held = stat(), visible = stat()
        guard fstat(fd, &held) == 0, lstat(root.path, &visible) == 0,
              held.st_dev == visible.st_dev, held.st_ino == visible.st_ino,
              fstat(folder, &held) == 0, fstatat(fd, reservation.id, &visible, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == visible.st_dev, held.st_ino == visible.st_ino,
              fstat(output, &held) == 0, fstatat(folder, name, &visible, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == visible.st_dev, held.st_ino == visible.st_ino else { throw ChatSessionTools.Failure(code: "download_unavailable") }
        complete = true
        guard case .object(var result) = reservation.file.mcpDescriptor else { throw ChatSessionTools.Failure(code: "download_unavailable") }
        result["path"] = .string(reservation.path.path)
        result["expires_at"] = .string(ISO8601DateFormatter().string(from: reservation.expires))
        return .object(result)
    }

    func remove(_ reservation: Reservation) {
        entries[reservation.id] = nil
        guard let fd = try? rootFD(create: false) else { return }
        defer { close(fd) }
        Self.removeDirectory(reservation.id, in: fd)
    }
    func remove(surface: String) { for item in Array(entries.values) where item.surface == surface { remove(item) } }
    func remove(key: ChatOrgKey) { for item in Array(entries.values) where item.key == key { remove(item) } }
    func cleanup() { for item in Array(entries.values) where item.expires <= now() { remove(item) } }
    func removeAll() {
        entries = [:]; watches = [:]; stamps = [:]
        guard let fd = try? rootFD(create: false) else { return }
        defer { close(fd) }
        // A private application directory only ever contains random UUIDs.
        for name in Self.names(fd) { Self.removeDirectory(name, in: fd) }
    }

    private static func names(_ fd: Int32) -> [String] {
        let copied = dup(fd)
        guard copied >= 0 else { return [] }
        guard let directory = fdopendir(copied) else { close(copied); return [] }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }
    private static func removeDirectory(_ name: String, in parent: Int32) {
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { unlinkat(parent, name, 0); return }
        for file in names(directory) { unlinkat(directory, file, 0) }
        close(directory)
        unlinkat(parent, name, AT_REMOVEDIR)
    }

    private func watch(_ key: ChatOrgKey, store: ChatStore) {
        guard watches[key] == nil else { return }
        watches[key] = ValueObservation.tracking { db in
            let generation = try String.fetchOne(db, sql: "SELECT generation FROM meta WHERE id = 1") ?? ""
            let epoch = try Int.fetchOne(db, sql: "SELECT channel_access_epoch FROM meta WHERE id = 1") ?? -1
            let doubt = try Bool.fetchOne(db, sql: "SELECT rights_in_doubt FROM meta WHERE id = 1") ?? true
            return "\(generation):\(epoch):\(doubt)"
        }.removeDuplicates().start(in: store.queue, scheduling: .immediate, onError: { [weak self] _ in
            self?.remove(key: key)
        }) { [weak self] stamp in
            guard let self else { return }
            if let previous = stamps[key], previous != stamp { remove(key: key) }
            stamps[key] = stamp
        }
    }
}
