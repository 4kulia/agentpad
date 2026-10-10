import AppKit
import Foundation
import Observation
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class SearchReviewModelTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("search-review-\(UUID())") }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    private func makeModel() -> EverywhereSearchModel {
        let index = ConversationIndex(directory: root.appendingPathComponent("search"), roots: ["claude-code": root.appendingPathComponent("claude")], throttled: false, visibility: { .init(channelIds: []) })
        return EverywhereSearchModel(messages: .init(context: { nil }, availability: { .noTeam }, fetch: { _, _ in .init(hits: [], next: nil) }),
            indexing: .init(index: index), catalog: .init(scan: { _ in .init(records: [], scanned: 0, total: 0, skipped: 0) }),
            names: SessionNames(url: root.appendingPathComponent("names.sqlite")), visibility: { .init(channelIds: []) })
    }
    private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Search did not settle")
    }
    private func openHistory() async throws -> (EverywhereSearchModel, URL) {
        let source = try SessionStoreFixtures.writeFile(UUID().uuidString + ".jsonl", in: root.appendingPathComponent("claude/project"), lines: [
            #"{"type":"user","uuid":"selected","cwd":"/project","message":{"content":"selectedword"}}"#])
        let model = makeModel(), index = model.indexing.index
        try await index.enable(rebuild: true); await index.refresh(force: true); await model.indexing.updateStatus()
        let page = try await index.search(SearchQuery("selectedword"))
        model.show(try XCTUnwrap(page.hits.first))
        try await settle { !model.contextLoading }
        XCTAssertFalse(model.context.isEmpty)
        return (model, source)
    }
    func testRevisionInvalidatesChangedOrRemovedSelectedTurnWithoutChangingEpoch() async throws {
        for remove in [false, true] {
            let (model, source) = try await openHistory()
            let epoch = model.indexing.status.state.epoch
            if remove { try FileManager.default.removeItem(at: source) }
            else {
                let changed = try String(contentsOf: source, encoding: .utf8).replacingOccurrences(of: "selectedword", with: "replacement")
                try changed.write(to: source, atomically: false, encoding: .utf8)
            }
            await model.indexing.index.refresh(force: true); await model.indexing.updateStatus()
            model.indexChanged()
            try await settle { model.selectedRecord == nil }
            XCTAssertNil(model.selectedHit); XCTAssertTrue(model.context.isEmpty); XCTAssertFalse(model.contextLoading)
            XCTAssertEqual(model.indexing.status.state.epoch, epoch)
            await model.indexing.clear()
        }
    }
    func testClearInvalidatesHistoryWithoutAnySearchFieldMounted() async throws {
        let (model, _) = try await openHistory()
        await model.indexing.clear()
        try await settle { model.selectedRecord == nil }
        XCTAssertNil(model.selectedHit); XCTAssertTrue(model.context.isEmpty); XCTAssertFalse(model.contextLoading)
    }
    func testQuickIndexBuiltOncePerSessionOffMainThread() async throws {
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var count = 0, main = false
            func record() { lock.withLock { count += 1; main = main || Thread.isMainThread } }
            var value: (Int, Bool) { lock.withLock { (count, main) } }
        }
        let model = makeModel(), calls = Calls()
        let item = PaletteItem(id: "agent", title: "Open Claude", subtitle: "agent", kind: .agent(templateId: "claude-code"), symbol: "terminal", iconAsset: nil)
        model.quickItems = { calls.record(); return [item] }
        model.begin()
        try await settle { !model.quick.isEmpty }
        model.query = "claude"
        for _ in 0..<10 { _ = model.quick; model.move(1); _ = model.choices }
        model.begin() // Focus callback for the same session.
        XCTAssertEqual(calls.value.0, 1); XCTAssertFalse(calls.value.1)
        model.dismiss(); model.begin()
        try await settle { calls.value.0 >= 2 }
        XCTAssertEqual(calls.value.0, 2)
    }
    func testQuickMatchesCacheOneSidebarSnapshotPerStateAndOneMatchPerQuery() async throws {
        let model = makeModel()
        let org = ChatOrgModel(me: "me") { _, _ in XCTFail("Search must not send commands"); return "unexpected" }
        let key = ChatOrgKey(server: try ChatServerAddress(parsing: "https://chat.example.com"), accountId: "me", orgId: "org")
        org.key = key
        var view = ChatOrgView(channelsServed: true, myAgents: (0..<200).map {
            .init(agentId: "agent-\($0)", ownerAccountId: "me", name: "Agent \($0)", description: "", access: "read", enabled: true, available: true)
        }, agentsServed: true)
        org.set(view)
        let items = view.myAgents.map {
            PaletteItem(id: $0.agentId, title: $0.name, subtitle: "agent", kind: .teamAgent(OrgKey(key), $0.agentId), symbol: "terminal", iconAsset: nil)
        }
        var snapshots = 0, matches = 0
        model.quickItems = { items }
        model.quickAllowedIDs = { items in
            snapshots += 1
            let allowed = Set(ChatSidebarSnapshot(model: org, active: nil).agents.map(\.id))
            return Set(items.filter { allowed.contains($0.id) }.map(\.id))
        }
        model.matchQuick = { query, items in
            matches += 1
            return PaletteIndex.match(query: query, in: items, limit: 6)
        }
        model.begin()
        try await settle { !model.quick.isEmpty }
        let initialSnapshots = snapshots, initialMatches = matches
        for _ in 0..<20 { _ = model.quick; model.move(1); _ = model.choices }
        XCTAssertEqual(snapshots, initialSnapshots); XCTAssertEqual(matches, initialMatches)
        model.query = "Agent 19"
        XCTAssertEqual(model.quick, PaletteIndex.match(query: model.query, in: items, limit: 6))
        for _ in 0..<20 { _ = model.quick; model.move(-1); _ = model.choices }
        XCTAssertEqual(snapshots, initialSnapshots, "Typing must not rebuild permissions or the sidebar")
        XCTAssertEqual(matches, initialMatches + 1)
        let changed = expectation(description: "Cached quick matches remain observable")
        withObservationTracking { _ = model.quick } onChange: { changed.fulfill() }
        view.myAgents = [view.myAgents[19]]; org.set(view)
        XCTAssertEqual(model.quick.map(\.id), ["agent-19"])
        XCTAssertEqual(snapshots, initialSnapshots + 1); XCTAssertEqual(matches, initialMatches + 2)
        await fulfillment(of: [changed], timeout: 1)
        var activated = false
        model.activateQuick = { _ in activated = true }
        view.rightsInDoubt = true; org.set(view)
        model.activate("q:agent-19")
        XCTAssertFalse(activated); XCTAssertTrue(model.quick.isEmpty)
        XCTAssertEqual(snapshots, initialSnapshots + 2); XCTAssertEqual(matches, initialMatches + 3)
        view.rightsInDoubt = false; org.set(view)
        XCTAssertEqual(model.quick.map(\.id), ["agent-19"])
        XCTAssertEqual(snapshots, initialSnapshots + 3)
        model.quickAllowedIDs = { _ in [] }
        XCTAssertTrue(model.quick.isEmpty, "Replacing the permission provider invalidates cached matches")
    }
    func testFirstFocusRequestReachesFieldCreatedByHiddenOrNarrowPresentation() async throws {
        struct DeferredField: View {
            let store: WorkspaceStore
            @Bindable var model: EverywhereSearchModel
            var body: some View {
                if model.focusRequest > 0 || model.fieldFocused { SearchEverywhereField(store: store, model: model) }
            }
        }
        for width in [CGFloat(800), 260] {
            let model = makeModel()
            let store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
                agentProfiles: AgentProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
                drafts: DraftRepository(fileURL: root.appendingPathComponent("drafts.json")), engineFactory: { TestEngine() })
            defer { store.terminate() }
            let host = NSHostingView(rootView: DeferredField(store: store, model: model))
            let window = SearchTestWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded(); model.begin()
            try await settle { host.layoutSubtreeIfNeeded(); return window.firstResponder is NSTextView }
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            editor.insertText("typed", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(model.query, "typed")
            editor.selectAll(nil); editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertFalse(model.suggestions)
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(window.firstResponder === editor, "Clearing a hidden/narrow field keeps it mounted for typing")
            editor.insertText("again", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(model.query, "again"); XCTAssertTrue(model.suggestions)
            model.dismiss()
            XCTAssertEqual(model.focusRequest, 0)
            model.begin()
            try await settle { host.layoutSubtreeIfNeeded(); return window.firstResponder is NSTextView }
        }
    }
}
