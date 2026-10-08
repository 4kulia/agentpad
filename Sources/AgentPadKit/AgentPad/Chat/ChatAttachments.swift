import CryptoKit
import Darwin
import Foundation
import GRDB
import ImageIO

/// ATT fields are deliberately optional on older servers; capability AND valid
/// advertised limits are required before exposing any file action.
struct ChatAttachmentLimits: Codable, Equatable, Sendable {
    var fileBytes: Int
    var messageFiles: Int
    var messageBytes: Int
    var pendingFiles: Int
    var pendingBytes: Int
    var uploadsPerAccount: Int
    var downloadsPerAccount: Int
    var uploadRequestSeconds: Int
    var imagePixels: Int
    var imageSide: Int
    var previewSide: Int
    var previewBytes: Int
    var draftTTLSeconds: Int
    var contextFiles: Int
    var contextBytes: Int
    var extensions: [String]
    var mimeTypes: [String]
    var verification: String
    enum CodingKeys: String, CodingKey {
        case fileBytes = "file_bytes", messageFiles = "message_files", messageBytes = "message_bytes"
        case pendingFiles = "pending_files", pendingBytes = "pending_bytes", uploadsPerAccount = "uploads_per_account"
        case downloadsPerAccount = "downloads_per_account", uploadRequestSeconds = "upload_request_seconds"
        case imagePixels = "image_pixels", imageSide = "image_side", previewSide = "preview_side", previewBytes = "preview_bytes"
        case draftTTLSeconds = "draft_ttl_seconds", contextFiles = "context_files", contextBytes = "context_bytes"
        case extensions, mimeTypes = "mime_types", verification
    }
    var valid: Bool {
        [fileBytes, messageFiles, messageBytes, pendingFiles, pendingBytes, uploadsPerAccount, downloadsPerAccount,
         uploadRequestSeconds, imagePixels, imageSide, previewSide, previewBytes, draftTTLSeconds, contextFiles, contextBytes].allSatisfy { $0 > 0 }
        && !extensions.isEmpty && !mimeTypes.isEmpty
    }
}

struct ChatAttachment: Codable, Equatable, Hashable, Sendable, Identifiable {
    var attachmentId: String
    var position: Int
    var name: String
    var mime: String
    var size: Int
    var hasPreview: Bool
    var width: Int?
    var height: Int?
    var id: String { attachmentId }
    var isImage: Bool { ["image/png", "image/jpeg"].contains(mime) }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id", position, name, mime, size, hasPreview = "has_preview", width, height
    }
}

struct ChatAttachmentManifest: Codable, Equatable, Sendable, Identifiable {
    var file: ChatAttachment
    var messageId: String
    var revision: Int
    var sha256: String
    var id: String { file.id }
    enum CodingKeys: String, CodingKey { case messageId = "message_id", revision, sha256 }
    init(file: ChatAttachment, messageId: String, revision: Int, sha256: String) {
        self.file = file; self.messageId = messageId; self.revision = revision; self.sha256 = sha256
    }
    init(from decoder: Decoder) throws {
        file = try ChatAttachment(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try c.decode(String.self, forKey: .messageId)
        revision = try c.decode(Int.self, forKey: .revision)
        sha256 = try c.decode(String.self, forKey: .sha256)
    }
    func encode(to encoder: Encoder) throws {
        try file.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(messageId, forKey: .messageId); try c.encode(revision, forKey: .revision); try c.encode(sha256, forKey: .sha256)
    }
    var reference: ChatJSON { .object(["message_id": .string(messageId), "revision": .number(Double(revision)), "attachment_id": .string(id)]) }
}

struct ChatAttachmentMetadata: Decodable, Sendable {
    var attachmentId: String
    var state: String
    var error: String?
    var expiresAt: String?
    var name: String?
    var mime: String?
    var size: Int?
    var hasPreview: Bool?
    var width: Int?
    var height: Int?
    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id", state, error, expiresAt = "expires_at", name, mime, size, hasPreview = "has_preview", width, height
    }
}

struct ChatAttachmentDraft: Codable, Equatable, Sendable, Identifiable {
    enum State: String, Codable, Sendable { case waiting, uploading, checking, ready, failed }
    var file: ChatAttachment
    var messageId: String
    var channel: String
    var root: String
    var session: String
    var generation: String
    var sha256: String
    var createdAt: Date
    var expiresAt: Date
    var prepareCommand = ChatUUID.v7()
    var completeCommand = ChatUUID.v7()
    var state: State = .waiting
    var progress: Double = 0
    var problem: String?
    /// Local ownership survives Send until the server confirms publication.
    var queued: Bool? = nil
    /// Bound to the stored bytes. Missing on drafts written before sanitization.
    var sanitizedImageSHA256: String? = nil
    var id: String { file.id }
    var prepareArgs: ChatJSON { .object([
        "attachment_id": .string(id), "channel_id": .string(channel), "message_id": .string(messageId),
        "name": .string(file.name), "size": .number(Double(file.size)), "mime": .string(file.mime), "sha256": .string(sha256)
    ]) }
}

enum ChatAttachments {
    static func migrateRetention(_ db: Database) throws {
        try db.execute(sql: """
            DROP TRIGGER attachment_channel_archived;
            DROP TRIGGER attachment_channel_deleted;
            CREATE TRIGGER attachment_channel_deleted AFTER DELETE ON channels
            WHEN (SELECT pending_generation FROM meta WHERE id = 1) IS NULL BEGIN
                DELETE FROM attachment_drafts WHERE channel_id = OLD.channel_id;
            END;
            """)
    }
    /// These versions follow authorization, not message windows or UI reads.
    /// Keep deleted channel versions so revoke/rejoin in one transaction cannot
    /// revive a directory whose observation has not run yet.
    static func migrateExecutionAccess(_ db: Database) throws {
        try db.create(table: "attachment_access_versions") { t in
            t.primaryKey("channel_id", .text); t.column("version", .integer).notNull()
        }
        try db.execute(sql: "INSERT INTO attachment_access_versions SELECT channel_id, 0 FROM channels")
        for event in ["INSERT", "DELETE"] {
            let row = event == "INSERT" ? "NEW" : "OLD"
            try db.execute(sql: """
                CREATE TRIGGER attachment_access_channel_\(event) AFTER \(event) ON channels BEGIN
                    INSERT INTO attachment_access_versions VALUES (\(row).channel_id, 1)
                    ON CONFLICT(channel_id) DO UPDATE SET version = version + 1;
                END
                """)
        }
        try db.execute(sql: """
            CREATE TRIGGER attachment_access_channel_change AFTER UPDATE OF team_id, archived ON channels
            WHEN OLD.team_id IS NOT NEW.team_id OR OLD.archived IS NOT NEW.archived BEGIN
                UPDATE attachment_access_versions SET version = version + 1 WHERE channel_id = NEW.channel_id;
            END;
            CREATE TRIGGER attachment_access_team_change BEFORE UPDATE OF mine ON teams WHEN OLD.mine IS NOT NEW.mine BEGIN
                UPDATE attachment_access_versions SET version = version + 1 WHERE channel_id IN (SELECT channel_id FROM channels WHERE team_id = OLD.team_id);
            END;
            CREATE TRIGGER attachment_access_team_delete BEFORE DELETE ON teams BEGIN
                UPDATE attachment_access_versions SET version = version + 1 WHERE channel_id IN (SELECT channel_id FROM channels WHERE team_id = OLD.team_id);
            END;
            CREATE TRIGGER attachment_access_authorization AFTER UPDATE OF rights_in_doubt, rights_session, generation, pending_generation ON meta
            WHEN OLD.rights_in_doubt IS NOT NEW.rights_in_doubt OR OLD.rights_session IS NOT NEW.rights_session
                OR OLD.generation IS NOT NEW.generation OR OLD.pending_generation IS NOT NEW.pending_generation BEGIN
                UPDATE attachment_access_versions SET version = version + 1;
            END;
            """)
    }
    static func migrate(_ db: Database) throws {
        try db.alter(table: "messages") { t in
            t.add(column: "attachments", .text).notNull().defaults(to: "[]")
            t.add(column: "attachment_only", .boolean).notNull().defaults(to: false)
        }
        try db.create(table: "content_read_versions") { t in
            t.primaryKey("request_id", .text); t.column("version", .integer).notNull()
        }
        try db.alter(table: "channel_call_intents") { t in t.add(column: "attachment_manifest", .text).notNull().defaults(to: "[]") }
        try db.alter(table: "drafts") { t in t.add(column: "attachment_selection", .text).notNull().defaults(to: "[]") }
        try db.create(table: "attachment_deleted_sources") { t in t.primaryKey("message_id", .text) }
        try db.create(table: "attachment_drafts") { t in
            t.primaryKey("attachment_id", .text)
            t.column("channel_id", .text).notNull()
            t.column("thread_root_id", .text).notNull()
            t.column("body", .text).notNull()
        }
        try db.execute(sql: """
            CREATE TRIGGER attachment_draft_removed AFTER DELETE ON attachment_drafts BEGIN
                UPDATE drafts SET attachment_selection = (
                    SELECT json_group_array(json(value)) FROM json_each(attachment_selection)
                    WHERE json_extract(value, '$.attachment_id') != OLD.attachment_id
                ), version = lower(hex(randomblob(16)))
                WHERE channel_id = OLD.channel_id AND thread_root_id = OLD.thread_root_id
                    AND EXISTS (SELECT 1 FROM json_each(attachment_selection) WHERE json_extract(value, '$.attachment_id') = OLD.attachment_id);
            END;
            CREATE TRIGGER attachment_channel_deleted AFTER DELETE ON channels BEGIN
                DELETE FROM attachment_drafts WHERE channel_id = OLD.channel_id;
            END;
            CREATE TRIGGER attachment_channel_archived AFTER UPDATE OF archived ON channels WHEN NEW.archived = 1 BEGIN
                DELETE FROM attachment_drafts WHERE channel_id = NEW.channel_id;
            END;
            CREATE TRIGGER attachment_team_revoked AFTER UPDATE OF mine ON teams WHEN OLD.mine = 1 AND NEW.mine = 0 BEGIN
                DELETE FROM attachment_drafts WHERE channel_id IN (SELECT channel_id FROM channels WHERE team_id = NEW.team_id);
            END;
            """)
    }
    static func drafts(_ db: Database, channel: String? = nil, root: String? = nil, includingQueued: Bool = false) throws -> [ChatAttachmentDraft] {
        let sql = channel == nil ? "SELECT body FROM attachment_drafts ORDER BY rowid" : "SELECT body FROM attachment_drafts WHERE channel_id = ? AND thread_root_id = ? ORDER BY rowid"
        return try String.fetchAll(db, sql: sql, arguments: channel.map { [$0, root ?? ""] } ?? []).map {
            try JSONDecoder().decode(ChatAttachmentDraft.self, from: Data($0.utf8))
        }.filter { includingQueued || $0.queued != true }
    }
    static func put(_ db: Database, _ draft: ChatAttachmentDraft) throws {
        let json = String(decoding: try JSONEncoder().encode(draft), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO attachment_drafts (attachment_id, channel_id, thread_root_id, body) VALUES (?, ?, ?, ?)
            ON CONFLICT(attachment_id) DO UPDATE SET channel_id = excluded.channel_id, thread_root_id = excluded.thread_root_id, body = excluded.body
            """,
                       arguments: [draft.id, draft.channel, draft.root, json])
    }
    static func bumpDraft(_ db: Database, channel: String, root: String) throws {
        try db.execute(sql: """
            INSERT INTO drafts (channel_id, thread_root_id, text, updated_at, version) VALUES (?, ?, '', ?, ?)
            ON CONFLICT(channel_id, thread_root_id) DO UPDATE SET version = excluded.version, updated_at = excluded.updated_at
            """, arguments: [channel, root, Date().timeIntervalSince1970, UUID().uuidString.lowercased()])
    }
    static func write(_ db: Database, id: String, files: [ChatAttachment], only: Bool) throws {
        let json = String(decoding: try JSONEncoder().encode(files), as: UTF8.self)
        try db.execute(sql: "UPDATE messages SET attachments = ?, attachment_only = ? WHERE message_id = ?", arguments: [json, only, id])
    }
    static func forgetMessage(_ db: Database, id: String) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO attachment_deleted_sources (message_id) VALUES (?)", arguments: [id])
        try db.execute(sql: "UPDATE channel_call_intents SET attachment_manifest = '[]' WHERE EXISTS (SELECT 1 FROM json_each(attachment_manifest) WHERE json_extract(value, '$.message_id') = ?)", arguments: [id])
        let rows = try Row.fetchAll(db, sql: "SELECT channel_id, thread_root_id, attachment_selection FROM drafts WHERE attachment_selection != '[]'")
        for row in rows {
            let previous = try JSONDecoder().decode([ChatAttachmentManifest].self, from: Data((row["attachment_selection"] as String).utf8))
            let kept = previous.filter { $0.messageId != id }
            if kept != previous {
                try db.execute(sql: "UPDATE drafts SET attachment_selection = ?, version = ? WHERE channel_id = ? AND thread_root_id = ?", arguments: [
                    String(decoding: try JSONEncoder().encode(kept), as: UTF8.self), UUID().uuidString.lowercased(), row["channel_id"] as String, row["thread_root_id"] as String])
            }
        }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func reason(_ error: Error) -> String {
        if let error = error as? ChatAPIError {
            switch error.code {
            case "too_large": return "File or message exceeds the server limit."
            case "storage_quota_exceeded": return "The organization’s file storage is full."
            case "rate_limited": return "Too many transfers. Try again later."
            case "upload_in_progress": return "The previous upload is being cleaned up. Try again shortly."
            case "attachment_expired": return "The server reservation expired. Retry to upload the saved file again."
            case "attachment_unconfirmed": return "The server was restored. This post was not confirmed; delete the saved files when no longer needed."
            case "invalid_file", "unsupported_media_type": return "The server could not verify this file’s format."
            case "channel_archived": return "The channel is archived."
            case "not_found", "unauthorized", "access_revoked": return "File unavailable."
            default: return "The file could not be transferred. Try again."
            }
        }
        return (error as? ChatAttachmentError)?.localizedDescription ?? "The file could not be transferred. Try again."
    }
}

enum ChatAttachmentError: String, Error, LocalizedError {
    case paused = "Attachments are paused: this server does not support them. Your files are saved locally."
    case expired = "The reservation expired and upload is unavailable. Your file is saved locally."
    case contextLost = "A selected context file is no longer available. The request cannot run; select the context again in a new request."
    case unavailable = "File unavailable."
    case type = "Choose PNG, JPEG, PDF or a supported UTF-8 text file."
    case animatedGIF = "Animated GIF attachments are not supported by this server. Choose another file."
    case source = "Choose a regular local file, not a folder, package, link or network location."
    case size = "The selected files exceed the server’s size or count limit."
    case name = "The file name is too long or contains unsupported characters."
    case changed = "The selected files changed. Review the draft before sending."
    case hash = "The file is incomplete or changed. Download it again."
    case folders = "The agent’s folders include AgentPad data, the temporary directory or Library. Choose a narrower project folder."
    case bash = "Attachments require the Read or Edit Files profile without Bash."
    var errorDescription: String? { rawValue }
}

/// Originals never acquire a persistent download cache. Only owned draft bytes
/// live here, using opaque UUID filenames, 0700 directories and 0600 files.
struct ChatAttachmentStorage: Sendable {
    let root: URL
    static var dataDirectory: URL { AgentPadShellIntegration.agentPadAppSupport("", isDirectory: true) }
    static var standard: Self { .init(root: dataDirectory.appendingPathComponent("attachments", isDirectory: true)) }
    func directory(_ key: ChatOrgKey) -> URL {
        root.appendingPathComponent(ChatAttachments.digest(Data("\(key.server)|\(key.accountId)|\(key.orgId)".utf8)), isDirectory: true)
    }
    func url(_ key: ChatOrgKey, id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw ChatAttachmentError.unavailable }
        return directory(key).appendingPathComponent(id.lowercased() + ".bytes")
    }
    static func secureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ChatAttachmentError.source }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    func save(_ data: Data, key: ChatOrgKey, id: String) throws {
        try Self.secureDirectory(root); try Self.secureDirectory(directory(key))
        try Self.write(data, to: url(key, id: id))
    }
    static func write(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ChatAttachmentError.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    func remove(_ key: ChatOrgKey, id: String) { if let url = try? url(key, id: id) { try? FileManager.default.removeItem(at: url) } }
    func prune(_ key: ChatOrgKey, keeping: Set<String>) {
        for url in (try? FileManager.default.contentsOfDirectory(at: directory(key), includingPropertiesForKeys: nil)) ?? [] {
            if !keeping.contains(url.deletingPathExtension().lastPathComponent) { try? FileManager.default.removeItem(at: url) }
        }
    }
    static func read(_ url: URL, limit: Int) throws -> Data {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { throw ChatAttachmentError.source }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .volumeIsLocalKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.isPackage != true, values.volumeIsLocal != false else { throw ChatAttachmentError.source }
        // A file inside an application/package is not a separately selected file.
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" {
            if (try? parent.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { throw ChatAttachmentError.source }
            parent.deleteLastPathComponent()
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ChatAttachmentError.source }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ChatAttachmentError.source }
        guard info.st_size > 0, info.st_size <= limit else { throw ChatAttachmentError.size }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count == info.st_size, data.count <= limit else { throw ChatAttachmentError.size }
        return data
    }
    static func descriptor(data: Data, name: String, limits: ChatAttachmentLimits) throws -> ChatAttachment {
        guard !name.isEmpty, name.utf8.count <= 200, !name.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || "/\\".unicodeScalars.contains($0) || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
        }) else { throw ChatAttachmentError.name }
        guard !data.isEmpty, data.count <= limits.fileBytes else { throw ChatAttachmentError.size }
        let ext = (name as NSString).pathExtension.lowercased()
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "pdf": "application/pdf", "txt": "text/plain", "md": "text/plain", "csv": "text/plain", "log": "text/plain", "json": "application/json"]
        guard let mime = types[ext], limits.extensions.contains(ext), limits.mimeTypes.contains(mime) else { throw ChatAttachmentError.type }
        var file = ChatAttachment(attachmentId: UUID().uuidString.lowercased(), position: 0, name: name, mime: mime, size: data.count, hasPreview: false)
        if file.isImage {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0, w <= limits.imageSide, h <= limits.imageSide, w <= limits.imagePixels / h else { throw ChatAttachmentError.type }
            file.width = w; file.height = h
        } else if mime == "application/pdf" {
            guard data.starts(with: Data("%PDF-".utf8)) else { throw ChatAttachmentError.type }
        } else {
            guard let text = String(data: data, encoding: .utf8), !text.unicodeScalars.contains(where: { $0.value == 0 || ($0.value < 32 && ![9, 10, 13].contains($0.value)) }) else { throw ChatAttachmentError.type }
            if ext == "json", (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) == nil { throw ChatAttachmentError.type }
        }
        return file
    }
    /// Managed bytes must never overlap a user grant in either direction.
    /// Narrow projects in Library/tmp remain usable, but call directories are
    /// reserved: only the directory supplied by this execution may be added.
    /// Resolve symlinks again at publication AND each process start.
    static func checkFolders(_ folders: [String], data: URL = dataDirectory, temporary: URL = FileManager.default.temporaryDirectory,
                             home: URL = FileManager.default.homeDirectoryForCurrentUser, executionDirectory: URL? = nil) throws {
        let protected = try [data, temporary, home.appendingPathComponent("Library")].map { try resolvedFolder($0.path) }
        let managed = protected[0], temp = protected[1]
        let execution = try executionDirectory.map { try resolvedFolder($0.path) }
        for folder in folders {
            let path = try resolvedFolder((folder as NSString).expandingTildeInPath)
            if protected.contains(where: { $0.relative(to: path) != nil }) { throw ChatAttachmentError.folders }
            if path.relative(to: managed) != nil { throw ChatAttachmentError.folders }
            if let relative = path.relative(to: temp), let name = relative.first, name.lowercased().hasPrefix("agentpad-call-") {
                guard let execution, path.relative(to: execution)?.isEmpty == true, relative.count == 1,
                      UUID(uuidString: String(name.dropFirst("agentpad-call-".count))) != nil,
                      FileManager.default.fileExists(atPath: path.url.appendingPathComponent(".agentpad-attachment-call").path) else { throw ChatAttachmentError.folders }
            }
        }
    }
    private struct Folder {
        struct Identity: Equatable {
            let device: dev_t
            let inode: ino_t
        }
        struct Ancestor {
            let url: URL
            let identity: Identity?
        }
        let url: URL
        let ancestors: [Ancestor]

        /// Compare every existing ancestor by filesystem identity. For a path
        /// not created yet, anchor its suffix at the last existing directory
        /// and use that volume's case rules (unknown fails closed).
        func relative(to parent: Folder) -> [String]? {
            guard let anchor = parent.ancestors.lastIndex(where: { $0.identity != nil }),
                  let index = ancestors.firstIndex(where: { $0.identity == parent.ancestors[anchor].identity }) else { return nil }
            let suffix = parent.ancestors.dropFirst(anchor + 1).map { $0.url.lastPathComponent }
            let candidate = ancestors.dropFirst(index + 1).map { $0.url.lastPathComponent }
            guard candidate.count >= suffix.count else { return nil }
            let sensitive = (try? parent.ancestors[anchor].url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames == true
            guard zip(suffix, candidate).allSatisfy({ sensitive ? $0 == $1 : $0.caseInsensitiveCompare($1) == .orderedSame }) else { return nil }
            return Array(candidate.dropFirst(suffix.count))
        }
    }
    /// Foundation leaves dangling symlinks unresolved. A grant must stay denied
    /// even before a managed directory is created for the first time.
    private static func resolvedFolder(_ path: String) throws -> Folder {
        var pending = URL(fileURLWithPath: path).pathComponents.dropFirst()[...]
        var result = URL(fileURLWithPath: "/"), links = 0
        while let part = pending.popFirst() {
            if part == "." { continue }
            if part == ".." { result.deleteLastPathComponent(); continue }
            let next = result.appendingPathComponent(part)
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: next.path) {
                links += 1
                guard links <= 40 else { throw ChatAttachmentError.folders }
                let parts = (target as NSString).pathComponents
                if target.hasPrefix("/") { result = URL(fileURLWithPath: "/") }
                pending = (parts.filter { $0 != "/" } + pending)[...]
            } else { result = next }
        }
        var ancestors: [Folder.Ancestor] = []
        var current = result
        while true {
            var info = stat()
            let found = stat(current.path, &info) == 0
            guard found || errno == ENOENT else { throw ChatAttachmentError.folders }
            if found, info.st_mode & S_IFMT != S_IFDIR { throw ChatAttachmentError.folders }
            ancestors.append(.init(url: current, identity: found ? .init(device: info.st_dev, inode: info.st_ino) : nil))
            if current.path == "/" { break }
            current.deleteLastPathComponent()
        }
        return Folder(url: result, ancestors: ancestors.reversed())
    }
}

extension ChatJSON {
    var withoutAttachmentDescriptors: ChatJSON {
        switch self {
        case .array(let values): return .array(values.map(\.withoutAttachmentDescriptors))
        case .object(var fields):
            fields["attachments"] = nil; fields["attachment_only"] = nil
            return .object(fields)
        default: return self
        }
    }
}
