import Observation
import XCTest
@testable import AgentPadKit

@MainActor
final class AttentionIndicatorTests: XCTestCase {
    func testEveryPriorityPairKeepsOneMarkAndRevealsTheNextReason() {
        for first in AttentionIndicator.Kind.allCases {
            for second in AttentionIndicator.Kind.allCases {
                let a = AttentionIndicator.Reason(id: "a", kind: first, summary: first.label)
                let b = AttentionIndicator.Reason(id: "b", kind: second, summary: second.label)
                let indicator = AttentionIndicator([a, b, a])
                XCTAssertEqual(indicator?.kind, min(first, second))
                XCTAssertEqual(indicator?.reasonIDs.count, 2)
                XCTAssertTrue(indicator?.accessibleSummary.contains(first.label) == true)
                XCTAssertEqual(AttentionIndicator([b])?.kind, second)
            }
        }
        XCTAssertNil(AttentionIndicator([]))
    }

    func testWorkspacePriorityIsIndependentOfListTierAndRawExitCannotReviveIt() async throws {
        let store = makeTestStore(), ledger = AttentionLedger()
        defer { store.terminate() }
        let workspace = try XCTUnwrap(store.active)
        let input = try XCTUnwrap(workspace.activeSession)
        let failed = store.addTab(in: workspace), finished = store.addTab(in: workspace)
        failed.activityState = .idle; failed.lastCommandExit = 1
        finished.notificationPhase = "turn"; finished.activityState = .attention; finished.attentionReason = .completion
        let notices = [(input, AttentionKind.input), (failed, .failure), (finished, .completion)].map { tab, kind in
            AttentionEvent(source: "terminal", object: tab.id.uuidString, episode: tab.attentionEpisode, kind: kind, destination: .terminal(tab.id))
        }
        for event in notices { ledger.upsert(event) }
        let model = AttentionSidebarModel(ledger: ledger, storesProvider: { [store] })
        let owner = AttentionWorkspaceID(window: store.windowID, workspace: workspace.id)
        XCTAssertEqual(model.workspaceIndicators[owner]?.kind, .needsInput)
        ledger.markAttentionViewed(notices[0]); await Task.yield()
        XCTAssertEqual(model.items.first?.indicatorKind, .finished, "List completion tier remains before failures")
        XCTAssertEqual(model.workspaceIndicators[owner]?.kind, .failed)
        ledger.markAttentionViewed(notices[1]); await Task.yield()
        XCTAssertEqual(model.workspaceIndicators[owner]?.kind, .finished)
        XCTAssertEqual(failed.lastCommandExit, 1)
        finished.activityState = .running; await Task.yield()
        XCTAssertNil(model.workspaceIndicators[owner], "Starting work removes the old completion")
        model.updateProjection()
        XCTAssertNil(model.tabIndicators[failed.id], "A saved nonzero exit is not a second attention source")
    }

    func testProjectionClearsAllReadoutsAndMovesOwnershipTogether() async throws {
        let a = makeTestStore(), b = makeTestStore(), ledger = AttentionLedger()
        defer { a.terminate(); b.terminate() }
        let workspace = try XCTUnwrap(a.active), pane = try XCTUnwrap(workspace.activePane)
        let tab = try XCTUnwrap(pane.activeTab), target = try XCTUnwrap(b.active?.activePane)
        tab.notificationPhase = "turn"; tab.activityState = .attention; tab.attentionReason = .completion
        let event = AttentionEvent(source: "terminal", object: tab.id.uuidString, episode: tab.attentionEpisode,
                                   kind: .completion, destination: .terminal(tab.id))
        ledger.upsert(event)
        let model = AttentionSidebarModel(ledger: ledger, storesProvider: { [a, b] })
        let sourceID = AttentionWorkspaceID(window: a.windowID, workspace: workspace.id)
        XCTAssertEqual(model.tabIndicators[tab.id]?.kind, .finished)
        XCTAssertEqual(model.workspaceIndicators[sourceID]?.kind, .finished)
        XCTAssertEqual(model.windowIndicators[a.windowID]?.kind, .finished)
        pane.tabs.removeAll { $0 === tab }; target.tabs.append(tab)
        await Task.yield()
        XCTAssertNil(model.workspaceIndicators[sourceID])
        XCTAssertNil(model.windowIndicators[a.windowID])
        XCTAssertEqual(model.windowIndicators[b.windowID]?.reasonIDs, [event.id])
        ledger.markAttentionViewed(event)
        await Task.yield()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.tabIndicators.isEmpty)
        XCTAssertTrue(model.workspaceIndicators.isEmpty)
        XCTAssertTrue(model.windowIndicators.isEmpty)
        ledger.upsert(event)
        await Task.yield()
        XCTAssertTrue(model.tabIndicators.isEmpty)
        XCTAssertEqual(tab.activityState, .attention)
        XCTAssertEqual(ledger.events.map(\.id), [event.id])
    }

    func testReadoutsAndEqualRefreshNeverBuildDuringRender() async throws {
        let store = makeTestStore(), ledger = AttentionLedger()
        var reads = 0
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession)
        let model = AttentionSidebarModel(ledger: ledger, storesProvider: { reads += 1; return [store] })
        let builds = model.projectionBuildCount, captures = reads
        for _ in 0..<100 {
            _ = model.items; _ = model.tabIndicators[tab.id]
            _ = model.workspaceIndicators; _ = model.windowIndicators
        }
        XCTAssertEqual(reads, captures)
        XCTAssertEqual(model.projectionBuildCount, builds)
        model.updateProjection()
        XCTAssertEqual(model.projectionBuildCount, builds)
        store.toggleWorkspaceRail(); store.toggleNavigationPanel()
        await Task.yield()
        XCTAssertEqual(model.projectionBuildCount, builds)
        ledger.upsert(.init(source: "terminal", object: tab.id.uuidString, episode: tab.attentionEpisode,
                            kind: .input, destination: .terminal(tab.id)))
        await Task.yield()
        XCTAssertEqual(model.projectionBuildCount, builds + 1, "Publish on source change without any getter")
    }

    func testRepeatedTerminalTitlesRenamesAndCwdChangesNeverRebuildOrPublishMarks() async throws {
        let isolation = TeamServiceTestScope()
        defer { isolation.close() }
        let store = makeTestStore(), ledger = AttentionLedger()
        var captures = 0
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession)
        let engine = try XCTUnwrap(tab.engine as? TestEngine)
        let event = AttentionEvent(source: "terminal", object: tab.id.uuidString, episode: tab.attentionEpisode,
                                   kind: .input, destination: .terminal(tab.id))
        ledger.upsert(event)
        let model = AttentionSidebarModel(ledger: ledger, storesProvider: { captures += 1; return [store] })
        let item = try XCTUnwrap(model.items.first), indicator = try XCTUnwrap(model.tabIndicators[tab.id])
        let original = model.projection, builds = model.projectionBuildCount, reads = captures
        let publications = Changes(), titleChanges = Changes()
        withObservationTracking { _ = model.projection } onChange: {
            MainActor.assumeIsolated { publications.count += 1 }
        }
        withObservationTracking { _ = model.title(for: item) } onChange: {
            MainActor.assumeIsolated { titleChanges.count += 1 }
        }
        func checkTitle(_ title: String) {
            XCTAssertEqual(model.tabTitle(tab), title)
            XCTAssertEqual(model.title(for: item), title, "Existing attention rows resolve the current name lazily")
            XCTAssertEqual(model.tooltip(indicator), title + ": " + item.subtitle)
            XCTAssertEqual(store.workspaceRailEntries(attention: model).flatMap(\.tabs).first { $0.id == tab.id }?.title, title)
        }
        let updates = 50
        for index in 0..<updates {
            // Delivered OSC updates, after the terminal's independent throttle.
            tab.terminalTitle = "Tokens: \(index)"
            await Task.yield()
            checkTitle("Tokens: \(index)")
        }
        for index in 0..<updates {
            store.renameTab(tab, to: "Renamed \(index)")
            await Task.yield()
            checkTitle("Renamed \(index)")
        }
        store.renameTab(tab, to: ""); tab.terminalTitle = nil
        for index in 0..<updates {
            engine.emitPwd("/tmp/attention-cwd-\(index)")
            await Task.yield()
            checkTitle("attention-cwd-\(index)")
        }
        XCTAssertEqual(titleChanges.count, 1, "Title readers must still be invalidated")
        XCTAssertEqual(captures, reads, "Title-only updates must not scan the shared sources")
        model.updateProjection() // A periodic refresh must also ignore the changed title/cwd.
        XCTAssertEqual(model.projectionBuildCount - builds, 0)
        XCTAssertEqual(publications.count, 0)
        XCTAssertEqual(model.projection, original)
        ledger.markAttentionViewed(event)
        await Task.yield()
        XCTAssertEqual(model.projectionBuildCount - builds, 1)
        XCTAssertEqual(publications.count, 1, "Attention changes still publish without a render")
        XCTAssertTrue(model.tabIndicators.isEmpty)
    }

    @MainActor private final class Changes { var count = 0 }

    func testServerConfirmationPersistsThroughViewAndInFlight() async throws {
        let store = makeTestStore(), ledger = AttentionLedger()
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession)
        var event = AttentionEvent(source: "tab-confirmation", object: "confirmation", kind: .confirmation,
                                   destination: .tabAction(tabID: tab.id, actionID: UUID()))
        ledger.upsert(event)
        let model = AttentionSidebarModel(ledger: ledger, storesProvider: { [store] })
        ledger.markAttentionViewed(event)
        event.actionInFlight = true; ledger.upsert(event)
        await Task.yield()
        XCTAssertEqual(model.tabIndicators[tab.id]?.kind, .needsInput)
        XCTAssertTrue(model.items.first?.inFlight == true)
        ledger.resolve(event.id)
        await Task.yield()
        XCTAssertNil(model.tabIndicators[tab.id])
    }
}
