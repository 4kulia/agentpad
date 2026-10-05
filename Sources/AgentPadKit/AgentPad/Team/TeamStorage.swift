import Darwin
import Foundation

/// Team state on disk: the agents published here, the calls they served and
/// their run logs, in `Application Support/agentpad/team-server/`. The folder
/// is 0700 and every file 0600. The `team/` folder of AgentPad 1.0.x (direct
/// mode) is neither read nor moved.
struct TeamStorage: Sendable {
    let directory: URL

    init(directory: URL) {
        // Fail before any read, write, or eager TeamService initialization.
        // Never silently redirect a test that forgot to inject its storage.
        precondition(!Self.isTestProcess || Self.testDirectoryIsSafe(directory),
                     "Tests must use temporary TeamStorage outside ~/Library/Application Support/agentpad")
        self.directory = directory
    }

    static var isTestProcess: Bool { NSClassFromString("XCTestCase") != nil }

    static func testDirectoryIsSafe(_ directory: URL) -> Bool {
        let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
        // Include the account's actual home even when the test process uses
        // CFFIXED_USER_HOME to isolate other application support files.
        let homes = [FileManager.default.homeDirectoryForCurrentUser,
                     URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))]
        return homes.allSatisfy { home in
            let profile = home.appendingPathComponent("Library/Application Support/agentpad")
                .standardizedFileURL.resolvingSymlinksInPath().path
            return path != profile && !path.hasPrefix(profile + "/")
        }
    }

    static var standard: TeamStorage {
        TeamStorage(directory: AgentPadShellIntegration.agentPadAppSupport(directoryName, isDirectory: true))
    }

    /// Also known to `agentpad-cli team watch` (AgentPadTeamWatch).
    static let directoryName = "team-server"

    var agentsURL: URL { directory.appendingPathComponent("agents.json") }
    var threadsURL: URL { directory.appendingPathComponent("threads.json") }
    var callsURL: URL { directory.appendingPathComponent("calls.json") }
    /// `runs/<callId>.jsonl`: what each call's agent did, for watching it.
    func runLogURL(callId: String) -> URL {
        directory.appendingPathComponent("runs", isDirectory: true).appendingPathComponent("\(callId.lowercased()).jsonl")
    }

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
            // Written and made private beside the target, then put in its
            // place in one rename: the file is either the old one or the
            // complete new one, never a new one that a later step failed on.
            let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temp) }
            let data = try encoder.encode(value)
            guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard rename(temp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            throw TeamError.storage("cannot write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
