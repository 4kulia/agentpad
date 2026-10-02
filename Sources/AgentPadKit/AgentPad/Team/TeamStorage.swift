import Darwin
import Foundation

/// Team state on disk, in `Application Support/agentpad/team/` (TEAM.md 7.7).
/// The folder is 0700 and every file 0600. Deleting the folder returns the
/// app to "team work not set up".
struct TeamStorage: Sendable {
    let directory: URL

    static var standard: TeamStorage {
        TeamStorage(directory: AgentPadShellIntegration.agentPadAppSupport("team", isDirectory: true))
    }

    var identityURL: URL { directory.appendingPathComponent("identity.key") }
    var configURL: URL { directory.appendingPathComponent("config.json") }
    var contactsURL: URL { directory.appendingPathComponent("contacts.json") }
    var invitesURL: URL { directory.appendingPathComponent("invites.json") }

    func prepareDirectory() throws {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw TeamError.storage("cannot prepare \(directory.path): \(error.localizedDescription)")
        }
    }

    // MARK: Identity

    /// The endpoint's 32-byte secret key. The identity colleagues know this
    /// Mac by survives only as long as this file does, so any doubt about it
    /// stops team work instead of quietly replacing it with a new key. A new
    /// key is created with O_EXCL, so two starts cannot end up with two keys.
    func loadOrCreateIdentity(generate: () -> Data) throws -> Data {
        let path = identityURL.path
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw TeamError.identity("\(path) is not a regular file") }
            guard info.st_uid == getuid() else { throw TeamError.identity("\(path) belongs to another user") }
            guard info.st_mode & 0o077 == 0 else {
                throw TeamError.identity("\(path) is readable by other users; run chmod 600 on it")
            }
            guard let data = FileManager.default.contents(atPath: path) else { throw TeamError.identity("cannot read \(path)") }
            guard data.count == 32 else { throw TeamError.identity("\(path) holds \(data.count) bytes, not a 32-byte key") }
            return data
        }
        guard errno == ENOENT else {
            throw TeamError.identity("cannot inspect \(path): \(String(cString: strerror(errno)))")
        }
        try prepareDirectory()
        let key = generate()
        guard key.count == 32 else { throw TeamError.identity("generated key has \(key.count) bytes") }
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw TeamError.identity("cannot create \(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let written = key.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == key.count, fsync(fd) == 0 else { throw TeamError.identity("cannot write \(path)") }
        return key
    }

    // MARK: JSON files

    func load<T: Decodable>(_ type: T.Type, from url: URL, default fallback: T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: Data(contentsOf: url))
        } catch {
            throw TeamError.storage("cannot read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func save<T: Encodable>(_ value: T, to url: URL) throws {
        try prepareDirectory()
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw TeamError.storage("cannot write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
