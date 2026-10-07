import XCTest

final class ResourceBundleTests: XCTestCase {
    func testBundleModuleIsOnlyUsedByTheResourceResolver() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let paths = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertFalse(paths.isEmpty, "The guard must scan the source tree")
        let allowedPath = "AgentPadKit/App/Theme.swift"
        XCTAssertTrue(paths.contains(allowedPath), "The resource resolver must exist")
        let directAccessor = try NSRegularExpression(pattern: #"\bBundle\s*\.\s*module\b"#)

        for path in paths where path != allowedPath {
            let source = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            XCTAssertNil(
                directAccessor.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                "Sources/\(path): use agentPadResourceBundle() or Bundle.agentPadResources"
            )
        }
    }
}
