import Darwin
import Foundation

struct TelegramProfileManifest: Codable, Equatable, Sendable {
    enum Cleanup: String, Codable, Sendable { case none, logout, localOnly }
    var schemaVersion = 1
    let connectionID: UUID
    let environment: TelegramEnvironment
    var userID: String?
    var keyCreated = false
    var cleanup: Cleanup = .none
    // Older manifests used logoutConfirmed for the logOut RPC's Ok, which is
    // only acceptance. Ignore that legacy field; only a completed TDLib logout
    // may persist this new marker. Optional for existing schema-1 profiles.
    var logoutCompleted: Bool?
    var keyAccount: String { environment.rawValue + ":" + connectionID.uuidString }
}

/// Only the connector actor uses this lease. Its flock covers profile selection
/// as well as the database, so a second process cannot create a second account.
final class TelegramProfile: @unchecked Sendable {
    let root: URL
    let directory: URL
    var manifest: TelegramProfileManifest
    private let lock: Int32
    var database: URL { directory.appendingPathComponent("db", isDirectory: true) }
    var files: URL { directory.appendingPathComponent("files", isDirectory: true) }

    init(root: URL, directory: URL, manifest: TelegramProfileManifest, lock: Int32) {
        self.root = root; self.directory = directory; self.manifest = manifest; self.lock = lock
    }
    deinit { flock(lock, LOCK_UN); Darwin.close(lock) }

    func save() throws {
        try TelegramProfileStore.write(JSONEncoder().encode(manifest), to: directory.appendingPathComponent("profile.json"))
    }

    func bind(userID: Int64, environment: TelegramEnvironment) throws {
        guard environment == manifest.environment, userID > 0,
              manifest.userID == nil || manifest.userID == String(userID) else { throw TelegramStorageError.accountMismatch }
        manifest.userID = String(userID)
        try save()
    }

    func remove() throws {
        // Never follow a replaced profile or a symlink during deletion.
        try TelegramProfileStore.validate(directory, directory: true)
        try FileManager.default.removeItem(at: directory)
    }
}

public struct TelegramProfileStore: Sendable {
    let root: URL
    public init(root: URL) { self.root = root }
    public static var standard: Self {
        Self(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/agentpad/telegram", isDirectory: true))
    }

    func open(environment: TelegramEnvironment, create: Bool) throws -> TelegramProfile? {
        if !FileManager.default.fileExists(atPath: root.path) {
            guard create else { return nil }
            try Self.createParents(root)
        }
        try Self.validate(root, directory: true)
        let descriptor = Darwin.open(root.appendingPathComponent("profile.lock").path,
                                     O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw TelegramStorageError.unsafePath }
        var ownsLock = false
        defer { if !ownsLock { Darwin.close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              info.st_mode & S_IFMT == S_IFREG else { throw TelegramStorageError.unsafePath }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw TelegramStorageError.lockedProfile }
        let profiles = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "profile.lock" }
        guard profiles.count <= 1 else { throw TelegramStorageError.corruptProfile }
        let directory: URL
        let manifest: TelegramProfileManifest
        if let existing = profiles.first {
            guard let id = UUID(uuidString: existing.lastPathComponent) else { throw TelegramStorageError.corruptProfile }
            directory = existing
            try Self.validate(directory, directory: true)
            let manifestURL = directory.appendingPathComponent("profile.json")
            let bytes = try Self.read(manifestURL)
            guard let saved = try? JSONDecoder().decode(TelegramProfileManifest.self, from: bytes),
                  saved.schemaVersion == 1, saved.connectionID == id, saved.environment == environment else {
                throw TelegramStorageError.corruptProfile
            }
            manifest = saved
        } else {
            guard create else { return nil }
            let id = UUID()
            directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
            try Self.createDirectory(directory)
            manifest = TelegramProfileManifest(connectionID: id, environment: environment)
            try Self.write(JSONEncoder().encode(manifest), to: directory.appendingPathComponent("profile.json"))
        }
        for name in ["db", "files"] { try Self.createDirectory(directory.appendingPathComponent(name, isDirectory: true)) }
        ownsLock = true
        return TelegramProfile(root: root, directory: directory, manifest: manifest, lock: descriptor)
    }

    private static func createParents(_ directory: URL) throws {
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw TelegramStorageError.unsafePath }
            return
        }
        guard errno == ENOENT else { throw TelegramStorageError.io }
        try createParents(directory.deletingLastPathComponent())
        try createDirectory(directory)
    }

    static func createDirectory(_ directory: URL) throws {
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw TelegramStorageError.io }
        try validate(directory, directory: true)
    }

    static func validate(_ url: URL, directory: Bool) throws {
        // Check ancestors for symlinks too. Ancestor ownership/permissions may
        // differ (e.g. /Users); our own directories/files must be 0700/0600.
        var ancestor = url
        while ancestor.path != "/" {
            var info = stat()
            guard lstat(ancestor.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else {
                throw TelegramStorageError.unsafePath
            }
            if ancestor == url {
                guard info.st_uid == getuid(), info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
                      info.st_mode & 0o777 == (directory ? 0o700 : 0o600) else { throw TelegramStorageError.unsafePath }
            }
            ancestor.deleteLastPathComponent()
        }
    }

    static func read(_ url: URL) throws -> Data {
        try validate(url, directory: false)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramStorageError.io }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let bytes = try handle.read(upToCount: 64 * 1024), bytes.count < 64 * 1024 else { throw TelegramStorageError.corruptProfile }
        return bytes
    }

    static func write(_ data: Data, to url: URL) throws {
        try validate(url.deletingLastPathComponent(), directory: true)
        if FileManager.default.fileExists(atPath: url.path) { try validate(url, directory: false) }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TelegramStorageError.io }
        defer { Darwin.close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw TelegramStorageError.io }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw TelegramStorageError.io }
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw TelegramStorageError.io }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw TelegramStorageError.io }
    }
}
