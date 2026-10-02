import Darwin
import Foundation

/// A target emitted by libghostty after Cmd+Click link detection.
///
/// libghostty sends both real URLs and filesystem paths through the same
/// `GHOSTTY_ACTION_OPEN_URL` action. Foundation's `URL(string:)` accepts a
/// scheme-less path, but the resulting value is not a file URL and
/// LaunchServices cannot open it as a document. Keep the distinction explicit
/// so the AppKit callback never conflates the two again.
enum TerminalOpenTarget: Equatable {
    case url(URL)
    case file(TerminalFileReference)

    var url: URL {
        switch self {
        case .url(let url): url
        case .file(let reference): reference.url
        }
    }
}

struct TerminalFileReference: Equatable {
    let url: URL
    /// One-based source location parsed from `path:line[:column]` or
    /// `path#Lline[Ccolumn]`. LaunchServices has no generic jump-to-line
    /// contract, but retaining it keeps parsing honest and leaves a clean seam
    /// for editor-specific routing later.
    let line: Int?
    let column: Int?
}

enum TerminalOpenTargetResolver {
    typealias FileExists = (String) -> Bool

    static func resolve(
        _ rawValue: String,
        currentDirectory: URL?,
        fileExists: FileExists = { FileManager.default.fileExists(atPath: $0) }
    ) -> TerminalOpenTarget? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // `URL(string:)` treats a bare `main.swift:42` as a URL whose scheme
        // is `main.swift`. Prefer the filesystem interpretation when either
        // the literal colon filename or the location-stripped file exists.
        if let location = parseColonLocation(value),
           let fullURL = fileURL(for: value, currentDirectory: currentDirectory),
           let locationURL = fileURL(for: location.path, currentDirectory: currentDirectory),
           fileExists(fullURL.path) || fileExists(locationURL.path) {
            return resolveFile(
                path: value,
                fragment: nil,
                currentDirectory: currentDirectory,
                fileExists: fileExists
            ).map(TerminalOpenTarget.file)
        }

        if let candidate = URL(string: value) {
            if let scheme = candidate.scheme {
                guard scheme.caseInsensitiveCompare("file") == .orderedSame else {
                    return .url(candidate)
                }

                // A non-local file URL has an authority that is part of its
                // identity. Passing only `candidate.path` would silently turn
                // `file://server/share/a` into the unrelated local
                // `file:///share/a`; leave the URL intact for LaunchServices.
                if let host = candidate.host, !host.isEmpty,
                   host.caseInsensitiveCompare("localhost") != .orderedSame {
                    return .url(candidate)
                }

                return resolveFile(
                    path: candidate.path,
                    fragment: candidate.fragment,
                    currentDirectory: currentDirectory,
                    fileExists: fileExists
                ).map(TerminalOpenTarget.file)
            }

            // `src/file.swift#L42` is a scheme-less URL according to
            // Foundation, but still a filesystem reference for our purposes.
            // Only split a fragment that is recognisably a source location;
            // otherwise preserve `#` as a legal filename character.
            if candidate.fragment.flatMap(parseFragmentLocation) != nil {
                return resolveFile(
                    path: value,
                    fragment: candidate.fragment,
                    currentDirectory: currentDirectory,
                    fileExists: fileExists
                ).map(TerminalOpenTarget.file)
            }
        }

        return resolveFile(
            path: value,
            fragment: nil,
            currentDirectory: currentDirectory,
            fileExists: fileExists
        ).map(TerminalOpenTarget.file)
    }

    private static func resolveFile(
        path rawPath: String,
        fragment: String?,
        currentDirectory: URL?,
        fileExists: FileExists
    ) -> TerminalFileReference? {
        guard !rawPath.isEmpty else { return nil }

        let fragmentLocation = fragment.flatMap(parseFragmentLocation)
        let fragmentSuffix = fragment.map { "#\($0)" }
        let fragmentIsPathSuffix = fragmentSuffix.map(rawPath.hasSuffix) ?? false
        let pathWithoutFragment: String
        if let fragmentSuffix, fragmentLocation != nil, fragmentIsPathSuffix {
            pathWithoutFragment = String(rawPath.dropLast(fragmentSuffix.count))
        } else {
            pathWithoutFragment = rawPath
        }
        let embeddedLocation = parseColonLocation(pathWithoutFragment)
        let location = fragmentLocation ?? embeddedLocation.map { ($0.line, $0.column) }
        let pathWithoutLocation = embeddedLocation?.path ?? pathWithoutFragment

        guard let fullURL = fileURL(for: rawPath, currentDirectory: currentDirectory),
              let locationURL = fileURL(for: pathWithoutLocation, currentDirectory: currentDirectory)
        else { return nil }

        // A numeric colon suffix is legal in a macOS filename. Prefer the full
        // spelling when it exists; only interpret the suffix as line/column
        // metadata when the stripped path is the real file.
        if (fragmentLocation == nil || fragmentIsPathSuffix), fileExists(fullURL.path) {
            return TerminalFileReference(url: fullURL, line: nil, column: nil)
        }
        if location != nil, fileExists(locationURL.path) {
            return TerminalFileReference(url: locationURL, line: location?.0, column: location?.1)
        }

        // Preserve the useful semantic interpretation when the file disappears
        // between terminal output and click. LaunchServices will harmlessly
        // reject a still-missing file, while a recreated file can open.
        if let location {
            return TerminalFileReference(url: locationURL, line: location.0, column: location.1)
        }
        return TerminalFileReference(url: fullURL, line: nil, column: nil)
    }

    private static func fileURL(for rawPath: String, currentDirectory: URL?) -> URL? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url: URL
        if (expanded as NSString).isAbsolutePath {
            url = URL(fileURLWithPath: expanded)
        } else {
            guard let currentDirectory, currentDirectory.isFileURL else { return nil }
            url = currentDirectory.appendingPathComponent(expanded)
        }
        return url.standardizedFileURL
    }

    private static func parseColonLocation(
        _ value: String
    ) -> (path: String, line: Int, column: Int?)? {
        guard let lastColon = value.lastIndex(of: ":"),
              let lastNumber = positiveInteger(value[value.index(after: lastColon)...])
        else { return nil }

        let prefix = value[..<lastColon]
        if let secondColon = prefix.lastIndex(of: ":"),
           let line = positiveInteger(prefix[prefix.index(after: secondColon)...])
        {
            let path = String(prefix[..<secondColon])
            guard !path.isEmpty else { return nil }
            return (path, line, lastNumber)
        }

        let path = String(prefix)
        guard !path.isEmpty else { return nil }
        return (path, lastNumber, nil)
    }

    private static func parseFragmentLocation(_ fragment: String) -> (Int, Int?)? {
        guard fragment.first == "L" else { return nil }
        let body = fragment.dropFirst()
        if let columnMarker = body.lastIndex(of: "C"),
           let line = positiveInteger(body[..<columnMarker]),
           let column = positiveInteger(body[body.index(after: columnMarker)...])
        {
            return (line, column)
        }
        return positiveInteger(body).map { ($0, nil) }
    }

    private static func positiveInteger<S: StringProtocol>(_ value: S) -> Int? {
        guard !value.isEmpty, value.allSatisfy(\.isNumber),
              let number = Int(value), number > 0
        else { return nil }
        return number
    }
}

enum TerminalRemoteProcessDetector {
    private static let remoteProcessNames: Set<String> = [
        "ssh", "autossh", "mosh", "mosh-client",
    ]

    static func isRemoteProcessName(_ rawName: String) -> Bool {
        remoteProcessNames.contains(
            URL(fileURLWithPath: rawName).lastPathComponent.lowercased()
        )
    }

    static func isRemoteConnection(pid: pid_t?) -> Bool {
        guard let pid, pid > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = Int(proc_name(pid, &buffer, UInt32(buffer.count)))
        guard length > 0 else { return false }
        let bytes = buffer.prefix(length).map(UInt8.init(bitPattern:))
        return isRemoteProcessName(String(decoding: bytes, as: UTF8.self))
    }
}

extension URL {
    var isWebLink: Bool {
        guard let scheme else { return false }
        return scheme.caseInsensitiveCompare("http") == .orderedSame
            || scheme.caseInsensitiveCompare("https") == .orderedSame
    }
}
