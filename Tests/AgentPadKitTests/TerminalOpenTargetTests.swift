import XCTest
@testable import AgentPadKit

final class TerminalOpenTargetTests: XCTestCase {
    private let cwd = URL(fileURLWithPath: "/tmp/demo-project", isDirectory: true)

    private func resolve(
        _ raw: String,
        existing: Set<String> = [],
        currentDirectory: URL? = nil
    ) -> TerminalOpenTarget? {
        TerminalOpenTargetResolver.resolve(
            raw,
            currentDirectory: currentDirectory,
            fileExists: { existing.contains($0) }
        )
    }

    private func fileReference(
        _ raw: String,
        existing: Set<String> = [],
        currentDirectory: URL? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> TerminalFileReference? {
        guard case .file(let reference) = resolve(
            raw,
            existing: existing,
            currentDirectory: currentDirectory
        ) else {
            XCTFail("expected file target for \(raw)", file: file, line: line)
            return nil
        }
        return reference
    }

    func testWebURLRemainsURL() {
        let expected = URL(string: "https://example.com/docs?q=1#result")!
        XCTAssertEqual(resolve(expected.absoluteString), .url(expected))
    }

    func testExternalURLRequiresAKnownSchemeOrRegisteredHandler() {
        for raw in ["https://example.com", "HTTP://localhost:3000", "mailto:hello@example.com",
                    "ftp://example.com/file", "ssh://example.com", "file://server/share/a"] {
            XCTAssertEqual(TerminalOpenTargetResolver.externalURL(raw, hasHandler: { _ in
                XCTFail("Known schemes need no Launch Services lookup")
                return false
            }), URL(string: raw))
        }
        for raw in ["Makefile:42", "main.swift:42", "myapp:42", "custom://item"] {
            XCTAssertNil(TerminalOpenTargetResolver.externalURL(raw))
            XCTAssertNil(TerminalOpenTargetResolver.externalURL(raw, hasHandler: { _ in false }))
            XCTAssertEqual(TerminalOpenTargetResolver.externalURL(raw, hasHandler: { _ in true }), URL(string: raw))
        }
        for raw in ["file:///tmp/a", "file://localhost/tmp/a", "./a.swift", "Makefile"] {
            XCTAssertNil(TerminalOpenTargetResolver.externalURL(raw, hasHandler: { _ in
                XCTFail("Local files do not need Launch Services")
                return true
            }))
        }
    }

    func testExtensionlessFilenameWithLocationUsesExistingFile() {
        let path = cwd.appendingPathComponent("Makefile").path
        let reference = fileReference("Makefile:42:7", existing: [path], currentDirectory: cwd)
        XCTAssertEqual(reference?.url.path, path)
        XCTAssertEqual(reference?.line, 42)
        XCTAssertEqual(reference?.column, 7)
    }

    func testSchemeLookingLiteralFilenameStillWinsOverSourceLocation() {
        let path = cwd.appendingPathComponent("notes:2026").path
        let reference = fileReference("notes:2026", existing: [path], currentDirectory: cwd)
        XCTAssertEqual(reference?.url.path, path)
        XCTAssertNil(reference?.line)
    }

    func testOnlyHTTPAndHTTPSUseBrowserPreference() {
        XCTAssertTrue(URL(string: "https://example.com")!.isWebLink)
        XCTAssertTrue(URL(string: "http://localhost:3000")!.isWebLink)
        XCTAssertFalse(URL(string: "mailto:hello@example.com")!.isWebLink)
        XCTAssertFalse(URL(fileURLWithPath: "/tmp/example.swift").isWebLink)
    }

    func testAbsolutePathBecomesFileURL() {
        let reference = fileReference("/tmp/example.swift")
        XCTAssertEqual(reference?.url, URL(fileURLWithPath: "/tmp/example.swift"))
        XCTAssertNil(reference?.line)
        XCTAssertNil(reference?.column)
    }

    func testRelativePathResolvesAgainstSurfaceCwd() {
        let reference = fileReference(
            "Sources/AgentPad/main.swift",
            currentDirectory: cwd
        )
        XCTAssertEqual(
            reference?.url,
            URL(fileURLWithPath: "/tmp/demo-project/Sources/AgentPad/main.swift")
        )
    }

    func testRelativePathWithoutCwdIsRejected() {
        XCTAssertNil(resolve("Sources/AgentPad/main.swift"))
    }

    func testLineAndColumnSuffixAreRemovedFromExistingPath() {
        let path = "/tmp/demo-project/Sources/AgentPad/main.swift"
        let reference = fileReference(
            "Sources/AgentPad/main.swift:42:7",
            existing: [path],
            currentDirectory: cwd
        )
        XCTAssertEqual(reference?.url.path, path)
        XCTAssertEqual(reference?.line, 42)
        XCTAssertEqual(reference?.column, 7)
    }

    func testBareRelativeFilenameWithLocationIsNotTreatedAsURLScheme() {
        let path = "/tmp/demo-project/main.swift"
        let reference = fileReference(
            "main.swift:42:7",
            existing: [path],
            currentDirectory: cwd
        )
        XCTAssertEqual(reference?.url.path, path)
        XCTAssertEqual(reference?.line, 42)
        XCTAssertEqual(reference?.column, 7)
    }

    func testNumericCustomURLRemainsURLWithoutMatchingFile() {
        let expected = URL(string: "myapp:42")!
        XCTAssertEqual(
            resolve("myapp:42", currentDirectory: cwd),
            .url(expected)
        )
    }

    func testSingleLineSuffixIsRemoved() {
        let path = "/tmp/example.swift"
        let reference = fileReference(
            "\(path):91",
            existing: [path]
        )
        XCTAssertEqual(reference?.url.path, path)
        XCTAssertEqual(reference?.line, 91)
        XCTAssertNil(reference?.column)
    }

    func testExistingNumericColonFilenameWinsOverLocationParsing() {
        let path = "/tmp/archive:2026"
        let reference = fileReference(
            path,
            existing: [path, "/tmp/archive"]
        )
        XCTAssertEqual(reference?.url.path, path)
        XCTAssertNil(reference?.line)
        XCTAssertNil(reference?.column)
    }

    func testMissingLocationPathStillUsesSemanticSpelling() {
        let reference = fileReference(
            "/tmp/created-later.swift:12:3"
        )
        XCTAssertEqual(reference?.url.path, "/tmp/created-later.swift")
        XCTAssertEqual(reference?.line, 12)
        XCTAssertEqual(reference?.column, 3)
    }

    func testSourceLocationFragmentIsRemoved() {
        let path = "/tmp/demo-project/Sources/AgentPad/main.swift"
        let reference = fileReference(
            "Sources/AgentPad/main.swift#L18C4",
            existing: [path],
            currentDirectory: cwd
        )
        XCTAssertEqual(reference?.url.path, path)
        XCTAssertEqual(reference?.line, 18)
        XCTAssertEqual(reference?.column, 4)
    }

    func testExistingHashLocationFilenameWinsOverFragmentParsing() {
        let path = "/tmp/report#L18"
        let reference = fileReference(path, existing: [path, "/tmp/report"])
        XCTAssertEqual(reference?.url.path, path)
        XCTAssertNil(reference?.line)
        XCTAssertNil(reference?.column)
    }

    func testExplicitFileURLIsAFileTarget() {
        let path = "/tmp/example file.swift"
        var components = URLComponents(
            url: URL(fileURLWithPath: path),
            resolvingAgainstBaseURL: false
        )!
        components.fragment = "L33"
        let url = components.url!
        let reference = fileReference(
            url.absoluteString,
            existing: [path]
        )
        XCTAssertEqual(reference?.url.path, path)
        XCTAssertEqual(reference?.line, 33)
        XCTAssertNil(reference?.column)
    }

    func testRemoteAuthorityFileURLIsPreserved() {
        let expected = URL(string: "file://server/share/example.swift#L33")!
        XCTAssertEqual(resolve(expected.absoluteString), .url(expected))
    }

    func testTildePathExpandsToHome() {
        let reference = fileReference("~/Documents/example.swift")
        XCTAssertEqual(
            reference?.url.path,
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/example.swift")
                .path
        )
    }

    func testWhitespaceOnlyTargetIsRejected() {
        XCTAssertNil(resolve(" \n\t "))
    }

    func testRemoteProcessNamesAreDetected() {
        XCTAssertTrue(TerminalRemoteProcessDetector.isRemoteProcessName("ssh"))
        XCTAssertTrue(TerminalRemoteProcessDetector.isRemoteProcessName("/usr/local/bin/autossh"))
        XCTAssertTrue(TerminalRemoteProcessDetector.isRemoteProcessName("mosh-client"))
        XCTAssertFalse(TerminalRemoteProcessDetector.isRemoteProcessName("zsh"))
        XCTAssertFalse(TerminalRemoteProcessDetector.isRemoteProcessName("node"))
    }

    func testRelativeSuffixFallbackPreservesLocationsAndRequiresUniqueFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-suffix-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let found = try makeFile("docs/agentpad/mockups/no-modals.html", in: root)
        for (raw, line, column) in [("mockups/no-modals.html", nil, nil),
                                   ("mockups/no-modals.html:42:7", 42, 7),
                                   ("./mockups/no-modals.html#L18C4", 18, 4)] {
            let target = await backgroundResolve(raw, cwd: root)
            XCTAssertEqual(target, .file(.init(url: found, line: line, column: column)))
        }
        _ = try makeFile("other/mockups/no-modals.html", in: root)
        let ambiguous = await backgroundResolve("mockups/no-modals.html:42", cwd: root)
        XCTAssertEqual(ambiguous, .file(.init(url: root.appendingPathComponent("mockups/no-modals.html"), line: 42, column: nil)))
        let exact = try makeFile("mockups/no-modals.html", in: root)
        let preferred = await backgroundResolve("mockups/no-modals.html", cwd: root)
        XCTAssertEqual(preferred, .file(.init(url: exact, line: nil, column: nil)))
    }

    func testRelativeFallbackTriesGitRootBeforeSuffixSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-git-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let exact = try makeFile("mockups/no-modals.html", in: root)
        _ = try makeFile("docs/agentpad/mockups/no-modals.html", in: root)
        let cwd = root.appendingPathComponent("src/subfolder")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let initialized = await Task.detached { GitStatusFetcher.runGit(["init", "--quiet", root.path]) != nil }.value
        XCTAssertTrue(initialized)
        let target = await backgroundResolve("mockups/no-modals.html:9", cwd: cwd)
        XCTAssertEqual(target, .file(.init(url: exact, line: 9, column: nil)))
        try FileManager.default.removeItem(at: exact)
        let suffix = await backgroundResolve("mockups/no-modals.html", cwd: cwd)
        XCTAssertEqual(suffix, .file(.init(url: root.appendingPathComponent("docs/agentpad/mockups/no-modals.html"), line: nil, column: nil)))
    }

    func testRelativeSuffixFallbackCannotEscapeRootOrMatchDirectoryOrPartialComponent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-boundary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let outside = try makeFile("outside/mockups/no-modals.html", in: root)
        try FileManager.default.createSymbolicLink(at: cwd.appendingPathComponent("linked"), withDestinationURL: outside.deletingLastPathComponent().deletingLastPathComponent())
        _ = try makeFile("docs/notmockups/no-modals.html", in: cwd)
        try FileManager.default.createDirectory(at: cwd.appendingPathComponent("folders/mockups/no-modals.html"), withIntermediateDirectories: true)
        let missing = await backgroundResolve("mockups/no-modals.html", cwd: cwd)
        XCTAssertEqual(missing, .file(.init(url: cwd.appendingPathComponent("mockups/no-modals.html"), line: nil, column: nil)))
        let absolute = cwd.appendingPathComponent("missing/no-modals.html")
        let absoluteTarget = await backgroundResolve(absolute.path, cwd: cwd)
        XCTAssertEqual(absoluteTarget?.url, absolute)
    }

    func testRelativeSearchRejectsPartialScansAtEntryAndTimeLimits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-budget-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeFile("one.txt", in: root)
        _ = try makeFile("two.txt", in: root)
        await Task.detached {
            let exists: TerminalOpenTargetResolver.FileExists = { FileManager.default.fileExists(atPath: $0) }
            XCTAssertNil(TerminalRelativeFileLookup.find(["one.txt"], currentDirectory: root, fileExists: exists,
                                                         entryLimit: 1, timeLimit: .seconds(5)))
            let start = ContinuousClock.now
            var reads = 0
            XCTAssertNil(TerminalRelativeFileLookup.find(["one.txt"], currentDirectory: root, fileExists: exists,
                timeLimit: .seconds(1), now: {
                    reads += 1
                    return reads < 5 ? start : start + .seconds(2)
                }))
        }.value
    }

    func testRelativeFallbackPreservesLiteralColonFilenamePriority() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-literal-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let literal = try makeFile("nested/docs/archive:2026", in: root)
        _ = try makeFile("nested/docs/archive", in: root)
        let target = await backgroundResolve("docs/archive:2026", cwd: root)
        XCTAssertEqual(target, .file(.init(url: literal, line: nil, column: nil)))
    }

    private func makeFile(_ path: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        return url
    }

    private func backgroundResolve(_ raw: String, cwd: URL) async -> TerminalOpenTarget? {
        await TerminalLinkResolution.run {
            TerminalOpenTargetResolver.resolve(raw, currentDirectory: cwd, fileExists: {
                XCTAssertFalse(Thread.isMainThread, "File lookups must use the terminal link worker")
                return FileManager.default.fileExists(atPath: $0)
            })
        }
    }
}
