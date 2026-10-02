import XCTest
@testable import AgentPadKit

/// AgentPad: settings and files left by a build from before the rename keep
/// working (`LegacyNames`).
final class LegacyNamesTests: XCTestCase {
    func testLegacyThemePrefixReadsAsBundledTheme() throws {
        let preset = try XCTUnwrap(AgentPadTerminalTheme.presets.first)
        let legacy = LegacyNames.themePrefix + preset.id
        XCTAssertEqual(AgentPadTerminalTheme.preset(for: legacy)?.id, preset.id)
        XCTAssertEqual(
            AgentPadTerminalTheme.theme(for: legacy, in: AgentPadTerminalTheme.presets)?.id,
            preset.id
        )
    }

    func testCurrentPrefixIsUnchanged() {
        let value = AgentPadTerminalTheme.bundledStoredValuePrefix + "dracula"
        XCTAssertEqual(AgentPadTerminalTheme.normalizedStoredValue(value), value)
        XCTAssertEqual(AgentPadTerminalTheme.normalizedStoredValue("  My Theme "), "My Theme")
    }

    func testLegacyNamesAreNotRenamed() {
        // rebrand.py must leave this file alone; a rename would turn every
        // name below into the current one and silently drop the compatibility.
        XCTAssertFalse(LegacyNames.themePrefix.contains("agentpad"))
        XCTAssertFalse(LegacyNames.sleepHelperPath.contains("agentpad"))
        XCTAssertNotEqual(LegacyNames.sleepHelperPath, ClosedLidSleep.installedHelperPath)
    }
}
