import XCTest
@testable import AgentPadKit

@MainActor
final class AgentPadTerminalThemeTests: XCTestCase {
    func testBundledThemePaletteKeepsIndicesWhenLinesAreReordered() throws {
        let text = try bundledThemeText()
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let reordered = (
            lines.filter { !$0.hasPrefix("palette = ") }
                + lines.filter { $0.hasPrefix("palette = ") }.reversed()
        ).joined(separator: "\n")
        let theme = try XCTUnwrap(AgentPadTerminalTheme.parseBundledTheme(reordered, id: "one-dark"))

        XCTAssertEqual(theme, AgentPadTerminalTheme.preset(for: "one-dark"))
    }

    func testBundledThemePaletteRejectsMissingIndexDespiteSixteenLines() throws {
        let text = try bundledThemeText().replacingOccurrences(of: "palette = 15=", with: "palette = 0=")

        XCTAssertNil(AgentPadTerminalTheme.parseBundledTheme(text, id: "one-dark"))
    }

    func testBundledThemePaletteUsesLastValueForRepeatedIndex() throws {
        let text = try bundledThemeText() + "\npalette = 1=#010203\n"
        let theme = try XCTUnwrap(AgentPadTerminalTheme.parseBundledTheme(text, id: "one-dark"))

        XCTAssertTrue(theme.lines.contains("palette = 1=#010203"))
        XCTAssertTrue(theme.lines.contains("palette = 0=#282C34"))
        XCTAssertEqual(theme.lines.filter { $0.hasPrefix("palette = ") }.count, 16)
    }

    private func bundledThemeText() throws -> String {
        let resource = try XCTUnwrap(Bundle.module.url(forResource: "one-dark", withExtension: nil))
        return try String(contentsOf: resource, encoding: .utf8)
    }

    func testBundledThemesLoadFromPackagedGhosttyThemeFiles() throws {
        XCTAssertEqual(AgentPadTerminalTheme.presets.count, 42)
        XCTAssertEqual(
            Set(AgentPadTerminalTheme.presets.map(\.id)).count,
            AgentPadTerminalTheme.presets.count
        )
        let theme = try XCTUnwrap(AgentPadTerminalTheme.preset(for: "one-dark"))
        let resource = try XCTUnwrap(
            Bundle.module.url(forResource: "one-dark", withExtension: nil)
        )
        XCTAssertEqual(
            try String(contentsOf: resource, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .first.map(String.init),
            "# AgentPad theme: One Dark"
        )
        XCTAssertEqual(theme.title, "One Dark")
        XCTAssertEqual(theme.lines.first, "background = #282C34")
        XCTAssertEqual(theme.lines.filter { $0.hasPrefix("palette = ") }.count, 16)
    }

    func testPresetLookupAcceptsStableId() {
        let theme = AgentPadTerminalTheme.preset(for: "solarized-light")
        XCTAssertEqual(theme?.title, "Solarized Light")
        XCTAssertEqual(
            AgentPadTerminalTheme.preset(for: "agentpad:solarized-light"),
            theme
        )
    }

    func testPresetLookupAcceptsLegacyDisplayName() {
        let theme = AgentPadTerminalTheme.preset(for: "Solarized Light")
        XCTAssertEqual(theme?.id, "solarized-light")
    }

    func testPresetExpandsToConcreteGhosttyColors() {
        let theme = AgentPadTerminalTheme.preset(for: "dracula")
        XCTAssertEqual(theme?.lines.first, "background = #282A36")
        XCTAssertEqual(theme?.lines.filter { $0.hasPrefix("palette = ") }.count, 16)
    }

    func testNewPresetsAreRegistered() {
        for id in [
            "tokyo-night", "tokyo-day", "gruvbox-dark", "gruvbox-light",
            "ghostty-dark", "one-dark", "one-light",
        ] {
            XCTAssertNotNil(AgentPadTerminalTheme.preset(for: id), "missing preset \(id)")
        }
    }

    func testCodexOpenSourceThemeSetIsRegisteredWithConcreteTerminalColors() throws {
        let ids = [
            "ayu-dark", "ayu-light", "ayu-mirage",
            "catppuccin-macchiato", "catppuccin-mocha", "dracula-soft",
            "everforest-dark", "everforest-light",
            "github-dark-default", "github-dark-dimmed", "github-dark-high-contrast",
            "github-light-default", "github-light-high-contrast",
            "gruvbox-dark-hard", "gruvbox-dark-soft",
            "gruvbox-light-hard", "gruvbox-light-soft",
            "material-theme", "material-theme-darker", "material-theme-lighter",
            "material-theme-ocean", "material-theme-palenight",
            "monokai", "night-owl", "night-owl-light", "nord",
            "one-dark-pro", "rose-pine-moon",
        ]

        XCTAssertEqual(ids.count, 28)
        for id in ids {
            let theme = try XCTUnwrap(AgentPadTerminalTheme.preset(for: id), "missing preset \(id)")
            XCTAssertEqual(
                theme.lines.filter { $0.hasPrefix("palette = ") }.count,
                16,
                "incomplete ANSI palette for \(id)"
            )
            for line in theme.lines {
                let color = try XCTUnwrap(line.split(separator: "=").last)
                    .trimmingCharacters(in: .whitespaces)
                XCTAssertEqual(color.count, 7, "non-RGB color in \(id): \(line)")
                XCTAssertEqual(color.first, "#", "invalid color in \(id): \(line)")
                XCTAssertTrue(
                    color.dropFirst().allSatisfy(\.isHexDigit),
                    "invalid color in \(id): \(line)"
                )
            }
        }
    }

    func testBundledThemesAreAlphabeticalByDisplayName() {
        let titles = AgentPadTerminalTheme.presets.map(\.title)
        XCTAssertEqual(
            titles,
            titles.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
        )
    }

    func testGhosttyDarkMatchesPinnedLibghosttyDefaults() {
        let theme = AgentPadTerminalTheme.preset(for: "ghostty-dark")
        XCTAssertEqual(theme?.title, "Ghostty Dark")
        XCTAssertEqual(theme?.backgroundHex, "#282C34")
        XCTAssertEqual(theme?.foregroundHex, "#FFFFFF")
        XCTAssertEqual(theme?.lines.first, "background = #282C34")
        XCTAssertEqual(theme?.lines.filter { $0.hasPrefix("palette = ") }.count, 16)
        XCTAssertTrue(theme?.lines.contains("palette = 0=#1D1F21") == true)
        XCTAssertTrue(theme?.lines.contains("palette = 15=#EAEAEA") == true)
    }

    func testIsDarkClassifiesPresetsForPickerGrouping() {
        XCTAssertEqual(AgentPadTerminalTheme.preset(for: "tokyo-night")?.isDark, true)
        XCTAssertEqual(AgentPadTerminalTheme.preset(for: "gruvbox-dark")?.isDark, true)
        XCTAssertEqual(AgentPadTerminalTheme.preset(for: "ghostty-dark")?.isDark, true)
        XCTAssertEqual(AgentPadTerminalTheme.preset(for: "one-dark")?.isDark, true)
        XCTAssertEqual(AgentPadTerminalTheme.preset(for: "tokyo-day")?.isDark, false)
        XCTAssertEqual(AgentPadTerminalTheme.preset(for: "gruvbox-light")?.isDark, false)
        XCTAssertEqual(AgentPadTerminalTheme.preset(for: "one-light")?.isDark, false)
    }

    func testSettingsThemeSelectionPreservesUnknownRawTheme() {
        let state = AgentPadSettingsModel.themeSelection(for: "/Users/me/.config/ghostty/themes/custom")
        XCTAssertEqual(state.selection, AgentPadSettingsModel.customThemeSelection)
        XCTAssertEqual(
            AgentPadSettingsModel.persistedThemeValue(
                selection: state.selection,
                customRawValue: state.customRawValue
            ),
            "/Users/me/.config/ghostty/themes/custom"
        )
    }

    func testSettingsDefaultThemeSelectionClearsRawThemeWhenChosen() {
        let defaultSelection = AgentPadSettingsModel.themeSelection(for: nil).selection
        XCTAssertNil(
            AgentPadSettingsModel.persistedThemeValue(
                selection: defaultSelection,
                customRawValue: "/Users/me/.config/ghostty/themes/custom"
            )
        )
    }

    func testSettingsPresetThemeSelectionPersistsStableId() {
        let state = AgentPadSettingsModel.themeSelection(for: "Solarized Light")
        XCTAssertEqual(state.selection, "solarized-light")
        XCTAssertEqual(
            AgentPadSettingsModel.persistedThemeValue(
                selection: state.selection,
                customRawValue: nil
            ),
            "agentpad:solarized-light"
        )
    }

    func testFreshAppearanceDefaultsToSystemWithIndependentThemePair() {
        let preferences = AgentPadSettingsModel.themePreferences(
            appearance: [:],
            legacyRawTheme: nil
        )

        XCTAssertEqual(preferences.mode, .system)
        XCTAssertEqual(preferences.lightSelection, AgentPadTerminalTheme.defaultLightID)
        XCTAssertEqual(preferences.darkSelection, AgentPadTerminalTheme.defaultDarkID)
    }

    func testDefaultTemplateOptsNewInstallsIntoPairedThemes() throws {
        let data = try XCTUnwrap(AgentPadSettings.defaultTemplate.data(using: .utf8))
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any]
        )
        let appearance = try XCTUnwrap(parsed["appearance"] as? [String: Any])

        XCTAssertEqual(
            appearance["themeSchemaVersion"] as? Int,
            AgentPadSettings.pairedThemeSchemaVersion
        )
        XCTAssertEqual(
            AgentPadSettings.effectiveThemeValue(parsed: parsed, systemIsDark: false),
            AgentPadTerminalTheme.defaultLightStoredValue
        )
        XCTAssertEqual(
            AgentPadSettings.effectiveThemeValue(parsed: parsed, systemIsDark: true),
            AgentPadTerminalTheme.defaultDarkStoredValue
        )
    }

    func testLegacyDefaultKeepsGhosttyInheritance() {
        let parsed: [String: Any] = [
            "appearance": ["showSearchPill": false],
            "terminal": ["font-size": 14],
        ]

        XCTAssertNil(AgentPadSettings.effectiveThemeValue(parsed: parsed, systemIsDark: false))
        XCTAssertNil(AgentPadSettings.effectiveThemeValue(parsed: parsed, systemIsDark: true))
        XCTAssertFalse(
            AgentPadSettingsModel.shouldEnablePairedThemeSchema(
                appearance: ["showSearchPill": false],
                legacyRawTheme: nil
            )
        )
    }

    func testExplicitLegacyThemeOptsIntoLosslessMigration() {
        XCTAssertTrue(
            AgentPadSettingsModel.shouldEnablePairedThemeSchema(
                appearance: [:],
                legacyRawTheme: "dracula"
            )
        )
    }

    func testLegacyThemeMigratesToMatchingSideAndPreservesAppearance() {
        let light = AgentPadSettingsModel.themePreferences(
            appearance: [:],
            legacyRawTheme: "Solarized Light"
        )
        XCTAssertEqual(light.mode, .light)
        XCTAssertEqual(light.lightSelection, "solarized-light")
        XCTAssertEqual(light.darkSelection, AgentPadTerminalTheme.defaultDarkID)

        let dark = AgentPadSettingsModel.themePreferences(
            appearance: [:],
            legacyRawTheme: "dracula"
        )
        XCTAssertEqual(dark.mode, .dark)
        XCTAssertEqual(dark.lightSelection, AgentPadTerminalTheme.defaultLightID)
        XCTAssertEqual(dark.darkSelection, "dracula")
    }

    func testPairedThemesAndModeTakePrecedenceOverLegacyTheme() {
        let preferences = AgentPadSettingsModel.themePreferences(
            appearance: [
                "mode": "system",
                "lightTheme": "solarized-light",
                "darkTheme": "dracula",
            ],
            legacyRawTheme: "rose-pine"
        )

        XCTAssertEqual(preferences.mode, .system)
        XCTAssertEqual(preferences.lightSelection, "solarized-light")
        XCTAssertEqual(preferences.darkSelection, "dracula")
    }

    func testEffectiveThemeFollowsModeAndSystemAppearance() {
        let parsed: [String: Any] = [
            "appearance": [
                "mode": "system",
                "lightTheme": "solarized-light",
                "darkTheme": "dracula",
            ],
            "terminal": [:],
        ]
        XCTAssertEqual(
            AgentPadSettings.effectiveThemeValue(parsed: parsed, systemIsDark: false),
            "solarized-light"
        )
        XCTAssertEqual(
            AgentPadSettings.effectiveThemeValue(parsed: parsed, systemIsDark: true),
            "dracula"
        )

        let forcedLight: [String: Any] = [
            "appearance": ["mode": "light", "darkTheme": "dracula"],
            "terminal": [:],
        ]
        XCTAssertEqual(
            AgentPadSettings.effectiveThemeValue(parsed: forcedLight, systemIsDark: true),
            AgentPadTerminalTheme.defaultLightStoredValue
        )
    }

    func testEffectiveThemeStillAcceptsLegacyTerminalTheme() {
        let parsed: [String: Any] = ["terminal": ["theme": "rose-pine"]]
        XCTAssertEqual(
            AgentPadSettings.effectiveThemeValue(parsed: parsed, systemIsDark: false),
            "rose-pine"
        )
    }

    func testSystemAppearanceResolutionUsesAppKitAppearance() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let highContrastDark = try XCTUnwrap(NSAppearance(named: .accessibilityHighContrastDarkAqua))
        let highContrastLight = try XCTUnwrap(NSAppearance(named: .accessibilityHighContrastAqua))

        XCTAssertTrue(AgentPadAppearanceMode.resolvesSystemDark(appearance: dark))
        XCTAssertTrue(AgentPadAppearanceMode.resolvesSystemDark(appearance: highContrastDark))
        XCTAssertFalse(AgentPadAppearanceMode.resolvesSystemDark(appearance: light))
        XCTAssertFalse(AgentPadAppearanceMode.resolvesSystemDark(appearance: highContrastLight))
    }

    func testUserThemesLoadsGhosttyThemeDirectoryFiles() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let themeURL = dir.appendingPathComponent("My Custom Theme")
        try """
        # comments are ignored
        background = #101820
        foreground = "F2AA4C"
        palette = 0=#101820
        """.write(to: themeURL, atomically: true, encoding: .utf8)

        let themes = AgentPadTerminalTheme.userThemes(in: dir)
        XCTAssertEqual(themes.map(\.title), ["My Custom Theme"])
        XCTAssertEqual(themes.first?.storedValue, "My Custom Theme")
        XCTAssertEqual(themes.first?.backgroundHex, "#101820")
        XCTAssertEqual(themes.first?.foregroundHex, "F2AA4C")
        XCTAssertEqual(themes.first?.isDark, true)
    }

    func testUserThemesAreGroupedByBackgroundLuminance() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "background = #F8F8F8\nforeground = #202020\n"
            .write(
                to: dir.appendingPathComponent("Bright Custom"),
                atomically: true,
                encoding: .utf8
            )
        try "foreground = #FFFFFF\n"
            .write(
                to: dir.appendingPathComponent("Missing Background"),
                atomically: true,
                encoding: .utf8
            )

        let themes = AgentPadTerminalTheme.userThemes(in: dir)
        XCTAssertEqual(themes.first { $0.title == "Bright Custom" }?.isDark, false)
        XCTAssertEqual(themes.first { $0.title == "Missing Background" }?.isDark, true)
    }

    func testSettingsThemeSelectionAcceptsUserThemeByFileName() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Issue 17")
        try "background = #000000\nforeground = #ffffff\n"
            .write(to: url, atomically: true, encoding: .utf8)

        let custom = AgentPadTerminalTheme.userThemes(in: dir)
        let state = AgentPadSettingsModel.themeSelection(for: "Issue 17", in: AgentPadTerminalTheme.presets + custom)
        XCTAssertEqual(state.selection, "ghostty-user:Issue 17")
        XCTAssertEqual(
            AgentPadSettingsModel.persistedThemeValue(
                selection: state.selection,
                customRawValue: nil,
                in: AgentPadTerminalTheme.presets + custom
            ),
            "Issue 17"
        )
    }

    func testUnprefixedCollisionPrefersGhosttyUserThemeWhileNamespaceSelectsBundled() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "background = #010203\nforeground = #F0F0F0\n"
            .write(
                to: dir.appendingPathComponent("nord"),
                atomically: true,
                encoding: .utf8
            )

        let themes = AgentPadTerminalTheme.presets + AgentPadTerminalTheme.userThemes(in: dir)
        let legacy = AgentPadSettingsModel.themeSelection(for: "nord", in: themes)
        XCTAssertEqual(legacy.selection, "ghostty-user:nord")
        XCTAssertEqual(
            AgentPadSettingsModel.persistedThemeValue(
                selection: legacy.selection,
                customRawValue: nil,
                in: themes
            ),
            "nord"
        )

        let bundled = AgentPadSettingsModel.themeSelection(for: "agentpad:nord", in: themes)
        XCTAssertEqual(bundled.selection, "nord")
        XCTAssertEqual(
            AgentPadSettingsModel.persistedThemeValue(
                selection: bundled.selection,
                customRawValue: nil,
                in: themes
            ),
            "agentpad:nord"
        )

        try "background = #FDFDFD\nforeground = #101010\n"
            .write(
                to: dir.appendingPathComponent("one-light"),
                atomically: true,
                encoding: .utf8
            )
        let themesWithDefaultCollision = AgentPadTerminalTheme.presets
            + AgentPadTerminalTheme.userThemes(in: dir)
        let defaults = AgentPadSettingsModel.themePreferences(
            appearance: ["themeSchemaVersion": 2],
            legacyRawTheme: nil,
            in: themesWithDefaultCollision
        )
        XCTAssertEqual(defaults.lightSelection, AgentPadTerminalTheme.defaultLightID)
        XCTAssertEqual(defaults.darkSelection, AgentPadTerminalTheme.defaultDarkID)
    }

    func testGhosttyUserThemesDirectoryHonorsXDGConfigHome() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let xdg = AgentPadTerminalTheme.ghosttyUserThemesDirectory(
            environment: ["XDG_CONFIG_HOME": "/tmp/xdg"],
            homeDirectory: home
        )
        XCTAssertEqual(xdg.path, "/tmp/xdg/ghostty/themes")

        let fallback = AgentPadTerminalTheme.ghosttyUserThemesDirectory(
            environment: [:],
            homeDirectory: home
        )
        XCTAssertEqual(fallback.path, "/Users/example/.config/ghostty/themes")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpad-theme-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
