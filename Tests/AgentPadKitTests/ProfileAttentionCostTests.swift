import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class ProfileAttentionCostTests: XCTestCase {
    func testAttentionAggregationIsSharedUntilObservedStateChanges() async throws {
        let store = makeTestStore(), ledger = AttentionLedger()
        var reads = 0
        defer { store.terminate() }
        let session = try XCTUnwrap(store.active?.activeSession)
        let profile = try store.agentProfiles.add(template: .codex, folder: session.currentDirectory, name: "Original")
        session.profileID = profile.id
        let event = AttentionEvent(source: "terminal", object: session.id.uuidString, episode: session.attentionEpisode,
            kind: .input, destination: .terminal(session.id))
        ledger.upsert(event)
        let sidebar = AttentionSidebarModel(ledger: ledger, storesProvider: { reads += 1; return [store] })
        for _ in 0..<100 {
            XCTAssertEqual(sidebar.items.first?.subjectName, "Original")
            XCTAssertEqual(sidebar.terminalIDsNeedingAttention, [session.id])
        }
        XCTAssertEqual(reads, 1, "All rows and windows must share one attention projection")
        try store.agentProfiles.rename(profile.id, to: "Renamed")
        await Task.yield()
        XCTAssertEqual(sidebar.items.first?.subjectName, "Renamed")
        XCTAssertEqual(sidebar.terminalIDsNeedingAttention, [session.id])
        XCTAssertEqual(reads, 2)
        ledger.markAttentionViewed(event)
        await Task.yield()
        XCTAssertTrue(sidebar.items.isEmpty)
        XCTAssertTrue(sidebar.terminalIDsNeedingAttention.isEmpty)
        XCTAssertEqual(reads, 3)
        AgentMonitor.shared.windowGeneration += 1
        await Task.yield()
        XCTAssertTrue(sidebar.items.isEmpty)
        XCTAssertEqual(reads, 4, "Window membership invalidates the shared projection")
    }

    func testCollapsedProfilesDoNotCollectSessionHistory() throws {
        let scope = TeamServiceTestScope()
        defer { scope.close() }
        let profiles = AgentProfileStore()
        let directory = FileManager.default.temporaryDirectory
        for index in 0..<20 {
            _ = try profiles.add(template: .codex, folder: directory, name: "Agent \(index)", launchOptions: "--model \(index)")
        }
        var historyReads = 0
        let store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, agentProfiles: profiles,
            engineFactory: { TestEngine() }, peerStores: { historyReads += 1; return [] })
        defer { store.terminate() }
        let history = AgentSessionHistory(profiles: profiles); history.scan = { [] }
        let host = NSHostingView(rootView: AgentProfilesSection(store: store, history: history))
        host.frame = NSRect(x: 0, y: 0, width: 350, height: 1600)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(historyReads, 0, "Collapsed profiles must not scan sessions or build history rows")
        store.expandedAgentProfiles.insert(try XCTUnwrap(profiles.profiles.first?.id))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(historyReads, 0, "Expanding a profile loads its sessions")
    }

    func testSharedSurfaceMapCountsEachSessionOnceAndTracksLiveChangesAcrossWindows() async throws {
        let profiles = AgentProfileStore()
        let a = makeTestStore(agentProfiles: profiles), b = makeTestStore(agentProfiles: profiles)
        defer { a.terminate(); b.terminate() }
        let first = try XCTUnwrap(a.active?.activeSession), second = try XCTUnwrap(b.active?.activeSession)
        let profile = try profiles.add(template: .codex, folder: first.currentDirectory)
        first.profileID = profile.id; second.profileID = profile.id
        // Keep the first surface in a hidden workspace.
        _ = a.addEmptyWorkspace()
        let ledger = AttentionLedger(), sidebar = AttentionSidebarModel(ledger: ledger, storesProvider: { [a, b] })
        let input = AttentionEvent(source: "terminal", object: first.id.uuidString, episode: first.attentionEpisode,
            kind: .input, destination: .terminal(first.id))
        ledger.upsert(input)
        (first.engine as! TestEngine).emitCommandFinished(exit: 1, duration: 1)
        let failure = AttentionEvent(source: "terminal", object: first.id.uuidString, episode: first.attentionEpisode,
            kind: .failure, destination: .terminal(first.id))
        ledger.upsert(failure)
        ledger.upsert(AttentionEvent(source: "terminal", object: second.id.uuidString, episode: second.attentionEpisode,
            kind: .input, destination: .terminal(second.id)))
        await Task.yield()
        XCTAssertEqual(sidebar.terminalAttention[first.id]?.count, 2)
        XCTAssertEqual(sidebar.profileAttentionCounts[profile.id], 2, "Two reasons on one surface count as one session")
        first.customTitle = "Updated live title"
        await Task.yield()
        XCTAssertTrue(sidebar.terminalAttention[first.id]?.allSatisfy { sidebar.title(for: $0) == "Updated live title" } == true)
        first.engine.onUserInput?()
        await Task.yield()
        XCTAssertEqual(sidebar.terminalAttention[first.id]?.map(\.id), [input.id])
        ledger.markAttentionViewed(input)
        await Task.yield()
        XCTAssertNil(sidebar.terminalAttention[first.id])
        XCTAssertEqual(sidebar.profileAttentionCounts[profile.id], 1)
        b.closeTab(second, in: b.active!)
        await Task.yield()
        XCTAssertTrue(sidebar.profileAttentionCounts.isEmpty)
    }
}
