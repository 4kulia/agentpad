import XCTest
@testable import AgentPadKit

final class SessionDisplayMetadataTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/csm_agent")
    private let yesterday = Date(timeIntervalSince1970: 1_791_504_000)
    private var today: Date { yesterday.addingTimeInterval(86_400) }
    private func record(title: String = "", activity: Date? = nil, scan: Date? = nil,
                        custom: String? = nil, ai: String? = nil, summary: String? = nil, prompt: String? = nil) -> AgentSessionRecord {
        .init(agentId: "claude-code", conversationId: "one", title: title, cwd: folder,
              lastActivity: activity ?? yesterday, summary: summary, firstPrompt: prompt,
              customTitle: custom, aiTitle: ai, scannedAt: scan)
    }
    private func resolve(_ catalog: AgentSessionRecord? = nil, _ binding: AgentSessionRecord? = nil,
                         _ live: SessionDisplayMetadata.Live? = nil) -> SessionDisplayMetadata {
        SessionDisplayMetadata.resolve(catalog: catalog, binding: binding, live: live, folderName: folder.lastPathComponent)
    }

    func testFieldPriorityAcrossSourcesAndFreshnessWithinEachField() {
        let catalog = record(scan: yesterday, custom: "Old name", ai: "Catalog AI", summary: "Summary", prompt: "Prompt")
        let binding = record(scan: today, custom: "Fresh name", ai: "Fresh AI")
        XCTAssertEqual(resolve(catalog, binding).title, "Fresh name")
        XCTAssertEqual(resolve(binding, catalog).title, "Fresh name")
        XCTAssertEqual(resolve(record(scan: today, ai: "Fresh AI"), catalog).title, "Old name", "Custom titles precede AI titles across sources")
        XCTAssertEqual(resolve(record(scan: today, summary: "New summary"), record(scan: yesterday, ai: "AI title")).title, "AI title")
        XCTAssertEqual(resolve(record(summary: "Summary", prompt: "First prompt")).title, "Summary")
        XCTAssertEqual(resolve(record(prompt: "First prompt. More detail")).title, "First prompt")
        XCTAssertEqual(resolve(record(scan: today, ai: "Catalog"), record(scan: today, ai: "Binding")).title, "Catalog")
    }

    func testScanTimeChoosesTitleButMaximumRealActivityChoosesDate() {
        let catalog = record(activity: today, scan: yesterday, ai: "Old title")
        let binding = record(activity: yesterday, scan: today, ai: "Fresh title")
        XCTAssertEqual(resolve(catalog, binding).title, "Fresh title")
        XCTAssertEqual(resolve(catalog, binding).lastActivity, today)
        XCTAssertEqual(resolve(record(activity: yesterday, scan: today), record(activity: today, scan: yesterday)).lastActivity, today)
        XCTAssertEqual(resolve(catalog, binding, .init(hookStateAt: today.addingTimeInterval(60), startedAt: .distantFuture)).lastActivity, today.addingTimeInterval(60))
    }

    func testAdoptionActivityIsIgnoredWithoutRewritingRecord() {
        let adopted = record(title: "csm_agent", activity: .distantFuture)
        XCTAssertEqual(resolve(record(ai: "Actual title"), adopted).lastActivity, yesterday)
        XCTAssertEqual(resolve(nil, adopted, .init(templateTitle: "Claude Code", startedAt: today)).lastActivity, today)
        XCTAssertEqual(adopted.title, "csm_agent")
        XCTAssertEqual(adopted.lastActivity, .distantFuture)
    }

    func testLegacyScanProvenancePreservesRealActivityEvenForFolderTitle() {
        var binding = record(title: "csm_agent", activity: today)
        binding.agentTitle = "csm_agent"
        binding.fileURL = folder.appendingPathComponent("one.jsonl")
        binding.startedAt = yesterday
        let result = resolve(nil, binding)
        XCTAssertEqual(result.title, "Claude Code")
        XCTAssertEqual(result.lastActivity, today)
    }

    func testFolderAndTemplateValuesNeverMaskOtherFields() {
        for placeholder in ["csm_agent", "Claude Code", "Session in csm_agent", "  csm_agent \n"] {
            let catalog = record(title: placeholder, ai: placeholder, summary: placeholder, prompt: placeholder)
            XCTAssertEqual(resolve(catalog, record(ai: "Actual AI title")).title, "Actual AI title")
            XCTAssertEqual(resolve(catalog, nil, .init(terminalTitle: placeholder)).title, "Claude Code")
            XCTAssertEqual(resolve(record(ai: placeholder, summary: "Real summary")).title, "Real summary")
        }
    }

    func testExplicitNamesCanMatchFolderOrTemplate() {
        let catalog = record(custom: "Transcript name", ai: "AI title", summary: "Summary", prompt: "Prompt")
        for name in ["csm_agent", "Claude Code", "Session in csm_agent", "  csm_agent \n"] {
            let expected = name.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(resolve(catalog, nil, .init(manualTitle: name, customTitle: "Tab name")).title, expected)
            XCTAssertEqual(resolve(catalog, nil, .init(customTitle: name)).title, expected)
            XCTAssertEqual(resolve(record(custom: name, ai: "AI title")).title, expected)
            XCTAssertEqual(resolve(record(ai: "AI title"), record(custom: name)).title, expected)
        }
    }

    func testTerminalTitlesAreOnlyFallbacksAndPathsAreIgnored() {
        let live = SessionDisplayMetadata.Live(templateTitle: "Claude Code", terminalTitle: "Terminal title", startedAt: today)
        XCTAssertEqual(resolve(record(prompt: "Real prompt"), nil, live).title, "Real prompt")
        XCTAssertEqual(resolve(nil, nil, live).title, "Terminal title")
        for value in ["csm_agent", "Claude Code", "/tmp/csm_agent", "~/csm_agent", "./csm_agent", "../csm_agent", "project/src", "file:///tmp/csm_agent"] {
            XCTAssertEqual(resolve(nil, nil, .init(templateTitle: "Claude Code", terminalTitle: value, startedAt: today)).title, "Claude Code", value)
        }
        XCTAssertEqual(resolve(record(ai: "Saved name"), nil, .init(terminalTitle: "csm_agent")).title, "Saved name")
    }

    func testSentinelsNeverBeatRealActivityAndOnlyUnknownLiveUsesStart() {
        let binding = record(activity: .distantPast, scan: yesterday)
        XCTAssertEqual(resolve(nil, binding, .init(hookStateAt: .distantPast, startedAt: today)).lastActivity, today)
        XCTAssertEqual(resolve(record(activity: yesterday), binding, .init(startedAt: today)).lastActivity, yesterday)
        XCTAssertEqual(resolve(nil, binding, .init(hookStateAt: today, startedAt: yesterday)).lastActivity, today)
    }
}
