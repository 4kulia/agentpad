import XCTest
@testable import AgentPadKit

final class FuzzyMatcherTests: XCTestCase {
    func testEmptyQueryReturnsZero() {
        XCTAssertEqual(FuzzyMatcher.score(query: "", against: "anything"), 0)
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score(query: "xyz", against: "workspace"))
    }

    func testQueryLongerThanTargetIsNoMatch() {
        XCTAssertNil(FuzzyMatcher.score(query: "workspace", against: "ws"))
    }

    func testExactPrefixScoresHigherThanMidStringMatch() {
        // "wo" prefix-matches "workspace" (with prefix + consecutive
        // bonuses); same query subsequence-matches "twosome" mid-string
        // with only the consecutive bonus. Prefix should win clearly.
        let prefixScore = FuzzyMatcher.score(query: "wo", against: "workspace")
        let midScore = FuzzyMatcher.score(query: "wo", against: "twosome")
        XCTAssertNotNil(prefixScore)
        XCTAssertNotNil(midScore)
        XCTAssertGreaterThan(prefixScore!, midScore!)
    }

    func testWordBoundaryBonus() {
        // "p" matches "project-x" (start) and "demo-project" (after `-`).
        // Both should score; the boundary-after-hyphen one still beats a
        // mid-word match.
        let boundary = FuzzyMatcher.score(query: "p", against: "demo-project")
        let midWord = FuzzyMatcher.score(query: "p", against: "deepworld")
        XCTAssertNotNil(boundary)
        XCTAssertNotNil(midWord)
        XCTAssertGreaterThan(boundary!, midWord!)
    }

    func testConsecutiveBonusBeatsSpread() {
        // Neither target has prefix or boundary bonuses, isolating the
        // consecutive-match bonus as the sole differentiator: "abws"
        // matches w then s back-to-back (+3 consecutive), "awbs" matches
        // them with a gap (no consecutive bonus).
        let consecutive = FuzzyMatcher.score(query: "ws", against: "abws")
        let spread = FuzzyMatcher.score(query: "ws", against: "awbs")
        XCTAssertNotNil(consecutive)
        XCTAssertNotNil(spread)
        XCTAssertGreaterThan(consecutive!, spread!)
    }

    func testCaseInsensitive() {
        XCTAssertEqual(
            FuzzyMatcher.score(query: "WS", against: "workspace"),
            FuzzyMatcher.score(query: "ws", against: "Workspace")
        )
    }

    func testCJKQueryMatchesCJKTitle() {
        // Grapheme-cluster comparison should let CJK queries land. Without
        // this, IME users searching workspace titles like "项目1" would
        // get empty results despite obvious matches.
        XCTAssertNotNil(FuzzyMatcher.score(query: "项", against: "项目1"))
        XCTAssertNotNil(FuzzyMatcher.score(query: "项目", against: "我的项目1"))
        XCTAssertNil(FuzzyMatcher.score(query: "项", against: "abc"))
    }
}

final class PaletteIndexMatchTests: XCTestCase {
    private let items: [PaletteItem] = [
        PaletteItem(id: "1", title: "project-x", subtitle: "workspace",
                    kind: .workspace(workspaceId: UUID(), windowId: UUID()),
                    symbol: "folder", iconAsset: nil),
        PaletteItem(id: "2", title: "demo-project", subtitle: "workspace",
                    kind: .workspace(workspaceId: UUID(), windowId: UUID()),
                    symbol: "folder", iconAsset: nil),
        PaletteItem(id: "3", title: "Open Claude Code", subtitle: "agent",
                    kind: .agent(templateId: "claude-code"),
                    symbol: "sparkle", iconAsset: nil),
    ]

    func testEmptyQueryReturnsItemsInOrder() {
        let out = PaletteIndex.match(query: "", in: items)
        XCTAssertEqual(out.map(\.id), ["1", "2", "3"])
    }

    func testEmptyQueryRespectsLimit() {
        let out = PaletteIndex.match(query: "", in: items, limit: 2)
        XCTAssertEqual(out.count, 2)
    }

    func testFuzzyMatchSurfacesBestTitle() {
        // "proj" matches both project items; "project-x" (prefix) outscores
        // "demo-project" (mid-string post-boundary).
        let out = PaletteIndex.match(query: "proj", in: items)
        XCTAssertEqual(out.first?.id, "1", "prefix match wins")
        XCTAssertEqual(out.dropFirst().first?.id, "2")
    }

    func testWhitespaceOnlyQueryActsAsEmpty() {
        let out = PaletteIndex.match(query: "   ", in: items)
        XCTAssertEqual(out.map(\.id), ["1", "2", "3"])
    }

    func testSubtitleFallbackCatchesKindSearches() {
        // Typing "agent" should still surface the Claude row by subtitle
        // when no title matches — at half-score, so it ranks below any
        // title hit but isn't dropped.
        let out = PaletteIndex.match(query: "agent", in: items)
        XCTAssertTrue(out.contains(where: { $0.id == "3" }))
    }

    func testNoMatchReturnsEmpty() {
        let out = PaletteIndex.match(query: "zzzzzzz", in: items)
        XCTAssertTrue(out.isEmpty)
    }
}

@MainActor
final class PaletteIndexRecentFolderTests: XCTestCase {
    func testRecentFoldersBecomeOpenEntries() {
        let items = PaletteIndex.build(
            controllers: [],
            model: AgentPadSettingsModel.shared,
            recentFolders: [URL(fileURLWithPath: "/tmp/proj-x", isDirectory: true)]
        )

        let recent = items.filter {
            if case .openRecentFolder = $0.kind { return true }
            return false
        }
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.title, "proj-x")
        XCTAssertEqual(recent.first?.kind, .openRecentFolder(path: "/tmp/proj-x"))
        XCTAssertTrue(recent.first?.subtitle.hasPrefix("recent · ") == true)
    }

    func testNoRecentFoldersMeansNoEntries() {
        let items = PaletteIndex.build(controllers: [], model: AgentPadSettingsModel.shared)
        XCTAssertFalse(items.contains {
            if case .openRecentFolder = $0.kind { return true }
            return false
        })
    }
}
