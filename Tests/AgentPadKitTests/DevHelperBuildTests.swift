import XCTest

final class DevHelperBuildTests: XCTestCase {
    func testAppTargetDependsOnControlHelper() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let target = try NSRegularExpression(
            pattern: #"\.executableTarget\(\s*name:\s*"AgentPad",\s*dependencies:\s*\[([^\]]*)\]"#)
        let match = try XCTUnwrap(target.firstMatch(in: manifest,
            range: NSRange(manifest.startIndex..., in: manifest)))
        let range = try XCTUnwrap(Range(match.range(at: 1), in: manifest))
        let dependencies = manifest[range].split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // This must be a direct target dependency: a copy step or separately
        // building the helper in launch tests does not fix `swift run AgentPad`.
        XCTAssertEqual(dependencies, [#""AgentPadKit""#, #""agentpad-cli""#])
    }
}
