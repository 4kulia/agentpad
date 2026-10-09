import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class EverywhereSearchTests: XCTestCase {
    private var temporaryRoots: [URL] = []
    override func tearDown() async throws {
        for root in temporaryRoots { try? FileManager.default.removeItem(at: root) }
        temporaryRoots = []
    }
    private func model() -> EverywhereSearchModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-view-\(UUID())")
        temporaryRoots.append(root)
        let index = ConversationIndex(directory: root, roots: [:], visibility: { .init(channelIds: []) })
        return EverywhereSearchModel(messages: .init(context: { nil }, availability: { .noTeam }, fetch: { _, _ in XCTFail("No network without a team"); return .init(hits: [], next: nil) }),
                                     indexing: .init(index: index), catalog: .init(scan: { _ in .init(records: [], scanned: 0, total: 0, skipped: 0) }),
                                     names: SessionNames(url: root.appendingPathComponent("names.sqlite")), visibility: { .init(channelIds: []) })
    }
    func testKeyboardQuickMatchesAndReturnWithoutSelection() async throws {
        let model = model()
        let item = PaletteItem(id: "agent", title: "Open Claude Code", subtitle: "agent", kind: .agent(templateId: "claude-code"), symbol: "terminal", iconAsset: nil)
        var picked = false, opened = false
        model.quickItems = { [item] }; model.activateQuick = { picked = $0 == item }; model.openResults = { opened = true }
        model.begin()
        for _ in 0..<200 { if !model.quick.isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
        model.move(1); XCTAssertEqual(model.selected, "q:agent"); model.activate(); XCTAssertTrue(picked); XCTAssertFalse(opened)
        model.selected = nil; model.activate(); XCTAssertTrue(opened)
        model.suggestions = true; model.showResults(); XCTAssertFalse(model.suggestions)
    }
    func testMetadataSearchSurvivesIndexOffAndUsesWholeFolderPaths() {
        let records = [AgentSessionRecord(agentId: "gemini", conversationId: "one", title: "Release plan", cwd: URL(fileURLWithPath: "/a/project"), lastActivity: .now),
                       AgentSessionRecord(agentId: "kiro", conversationId: "two", title: "Release plan", cwd: URL(fileURLWithPath: "/b/project"), lastActivity: .now)]
        let hits = EverywhereSearchModel.metadataMatches(records: records, names: [:], query: "release", filter: .init(folder: "/a/project"))
        XCTAssertEqual(hits.map(\.conversationId), ["one"])
        let renamed = EverywhereSearchModel.metadataMatches(records: records, names: [records[1].nameKey: "Manual name"], query: "manual", filter: .init())
        XCTAssertEqual(renamed.map(\.conversationId), ["two"])
    }
    func testSourceSpecificFiltersNeverSendLocalFoldersOrTypes() {
        let model = model(); model.query = "release"; model.filter = .init(agent: "codex", folder: "/private/project")
        let request = model.serverRequest
        XCTAssertEqual(request.query, "release"); XCTAssertEqual(request.scope, .all); XCTAssertNil(request.targetID)
        let data = try! JSONEncoder().encode(request)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private"))
        model.source = .sessions; model.serverSearch(debounce: false); XCTAssertFalse(model.messages.loading)
        XCTAssertFalse(model.hasTeam)
    }
    func testSearchRouteIsWindowScopedAndPersistsNoQuery() throws {
        XCTAssertNotEqual(ToolRoute.search.key(windowID: UUID()), ToolRoute.search.key(windowID: UUID()))
        let data = try JSONEncoder().encode(ToolRoute.search)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"search\":{}}")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(TabNavigation()), as: UTF8.self).contains("query"))
    }
    func testFiltersAndBackKeepQueryAndScrollInMemory() {
        let model = model(); model.query = "release checklist"; model.source = .sessions; model.filter.folder = "/project"
        model.scrollID = "l:turn-18"
        model.selectedRecord = .init(agentId: "codex", conversationId: "session", title: "Release", cwd: URL(fileURLWithPath: "/project"), lastActivity: .now)
        model.selectedRecord = nil
        XCTAssertEqual(model.query, "release checklist"); XCTAssertEqual(model.scrollID, "l:turn-18"); XCTAssertEqual(model.filter.folder, "/project")
        let range = SearchDatePeriod.custom.range(now: .now, first: Date(timeIntervalSince1970: 0), last: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian))
        XCTAssertNotNil(range.0); XCTAssertGreaterThan(range.1!, range.0!)
        model.source = .messages; model.connectionChanged(); XCTAssertEqual(model.source, .all)
    }
    func testMatchingTurnOpensReadOnlyContextAndRendersPopulatedResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-populated-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("claude"), id = UUID().uuidString
        let lines = (1...20).map { n in
            #"{"type":"user","uuid":"turn-\#(n)","timestamp":"2026-10-09T12:00:00Z","cwd":"/project","message":{"content":"\#(n == 18 ? "The release checklist is ready for review." : "Context for turn \(n).")"}}"#
        }
        try SessionStoreFixtures.writeFile(id + ".jsonl", in: source.appendingPathComponent("project"), lines: lines)
        let index = ConversationIndex(directory: root.appendingPathComponent("search"), roots: ["claude-code": source], throttled: false, visibility: { .init(channelIds: []) })
        let controller = SearchIndexController(index: index)
        await controller.enable()
        for _ in 0..<200 {
            let status = await index.snapshot()
            if status.processed == 1 && !status.scanning { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await controller.updateStatus()
        let model = EverywhereSearchModel(messages: .init(context: { nil }, availability: { .noTeam }, fetch: { _, _ in XCTFail(); return .init(hits: [], next: nil) }),
            indexing: controller, catalog: .init(scan: { _ in .init(records: [], scanned: 0, total: 0, skipped: 0) }),
            names: SessionNames(url: root.appendingPathComponent("names.sqlite")), visibility: { .init(channelIds: []) })
        model.query = "release checklist"; model.localSearch(debounce: false)
        for _ in 0..<200 { if !model.localLoading { break }; try await Task.sleep(for: .milliseconds(5)) }
        let hit = try XCTUnwrap(model.local.first); XCTAssertEqual(hit.turn.id, "turn-18")
        var starts = 0
        let store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            agentProfiles: AgentProfileStore(fileURL: root.appendingPathComponent("profiles.json")), drafts: DraftRepository(fileURL: root.appendingPathComponent("drafts.json")),
            engineFactory: { starts += 1; return TestEngine() })
        defer { store.terminate() }
        let state = TabState(route: .search)
        func capture(_ name: String) throws {
            let host = NSHostingView(rootView: SearchResultsTab(model: model, state: state, store: store).preferredColorScheme(.dark))
            host.frame = NSRect(x: 0, y: 0, width: 1000, height: 680)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            if let output = ProcessInfo.processInfo.environment["AGENTPAD_SEARCH_CAPTURE"] {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
            }
            window.close()
        }
        try capture("search-populated")
        model.activate("l:" + hit.id)
        for _ in 0..<200 { if !model.contextLoading { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.context.count, 5); XCTAssertEqual(model.selectedHit?.turn.id, "turn-18"); XCTAssertNil(model.navigationError)
        try capture("search-matched-turn")
        XCTAssertEqual(starts, 0)
        await controller.clear()
    }
    func testResultsAndLocalHistoryRenderWithoutStartingAgent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var starts = 0
        let store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            agentProfiles: AgentProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
            drafts: DraftRepository(fileURL: root.appendingPathComponent("drafts.json")), engineFactory: { starts += 1; return TestEngine() })
        defer { store.terminate() }
        let model = model(); store.searchModel = model; model.query = "release checklist"
        let state = TabState(route: .search)
        for history in [false, true] {
            if history { model.selectedRecord = .init(agentId: "codex", conversationId: "fixture", title: "Release checklist", cwd: URL(fileURLWithPath: "/project"), lastActivity: .now) }
            let host = NSHostingView(rootView: SearchResultsTab(model: model, state: state, store: store).preferredColorScheme(.dark))
            host.frame = NSRect(x: 0, y: 0, width: 1000, height: 680)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let output = ProcessInfo.processInfo.environment["AGENTPAD_SEARCH_CAPTURE"] {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent(history ? "search-history.png" : "search-results.png"))
            }
            window.close()
        }
        XCTAssertEqual(starts, 0)
    }
}
