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
}
