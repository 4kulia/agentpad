import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class SearchSettingsTests: XCTestCase {
    func testFailedConsentWriteKeepsIndexingOffAndCanBeRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-consent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("search"), consent = root.appendingPathComponent("search-consent.json")
        let index = ConversationIndex(directory: directory, roots: [:], throttled: false)
        let controller = SearchIndexController(index: index)
        await controller.updateStatus()
        // Make the consent destination unwritable after the initial state load.
        try FileManager.default.createDirectory(at: consent, withIntermediateDirectories: true)
        try Data("block replacement".utf8).write(to: consent.appendingPathComponent("blocker"))
        await controller.enable()
        XCTAssertNotNil(controller.actionError)
        XCTAssertFalse(controller.status.state.enabled)
        await index.refresh(force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.removeItem(at: consent)
        await controller.enable()
        XCTAssertNil(controller.actionError); XCTAssertTrue(controller.status.state.enabled)
        await controller.clear()
    }
    func testControlsPersistPauseOffAndClearRequiresExplicitRebuildAcrossControllers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let index = ConversationIndex(directory: root.appendingPathComponent("search"), roots: [:], throttled: false, visibility: { .init(channelIds: []) })
        let controller = SearchIndexController(index: index)
        await controller.updateStatus(); XCTAssertFalse(controller.status.state.enabled)
        await controller.enable(); XCTAssertTrue(controller.status.state.enabled)
        await controller.pause(true); XCTAssertTrue(controller.status.state.paused)
        await controller.disable(); XCTAssertFalse(controller.status.state.enabled)
        await controller.enable(); XCTAssertFalse(controller.status.state.paused)
        await controller.clear(); XCTAssertTrue(controller.status.state.cleared); XCTAssertEqual(controller.status.bytes, 0)
        let second = SearchIndexController(index: index); await second.updateStatus(); XCTAssertTrue(second.status.state.cleared)
        await second.enable(); XCTAssertNotNil(second.actionError); XCTAssertFalse(second.status.state.enabled)
        await second.enable(rebuild: true); XCTAssertTrue(second.status.state.enabled); XCTAssertNil(second.actionError)
        await second.clear()
    }
    func testInterruptedClearFinishesBeforeOpeningIndexAndKeepsOtherFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-clear-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("search"), consent = root.appendingPathComponent("search-consent.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old index".utf8).write(to: directory.appendingPathComponent("conversations.sqlite"))
        let names = root.appendingPathComponent("session-names.sqlite"); try Data("names".utf8).write(to: names)
        try JSONEncoder().encode(SearchIndexState(enabled: false, cleared: true, clearing: true)).write(to: consent)
        let index = ConversationIndex(directory: directory, roots: [:], throttled: false)
        let status = await index.snapshot()
        XCTAssertTrue(status.state.cleared); XCTAssertFalse(status.state.clearing); XCTAssertFalse(status.state.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path)); XCTAssertEqual(try String(contentsOf: names, encoding: .utf8), "names")
    }
    func testSettingsRendersOffAndClearedInBothThemes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-settings-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let index = ConversationIndex(directory: root.appendingPathComponent("search"), roots: [:], throttled: false)
        let controller = SearchIndexController(index: index)
        let previous = AgentPadSettingsModel.testModel
        defer { AgentPadSettingsModel.testModel = previous }
        for cleared in [false, true] {
            if cleared { await controller.clear() }
            for dark in [false, true] {
                AgentPadSettingsModel.testModel = AgentPadSettingsModel(read: { ["appearance": ["mode": dark ? "dark" : "light"]] },
                    write: { _ in }, appliesRuntimeEffects: false)
                XCTAssertEqual(Theme.resolved.isLight, !dark)
                let host = NSHostingView(rootView: ScrollView { SearchSettingsView(controller: controller, autostart: false) }
                    .background(Theme.chromeBackground).environment(\.colorScheme, dark ? .dark : .light))
                host.frame = NSRect(x: 0, y: 0, width: 850, height: 850)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = Theme.windowAppearance; window.contentView = host; host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
                if let output = ProcessInfo.processInfo.environment["AGENTPAD_SEARCH_CAPTURE"] {
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent("search-settings-\(cleared ? "cleared" : "off")-\(dark ? "dark" : "light").png"))
                }
                window.close()
            }
        }
    }
}
