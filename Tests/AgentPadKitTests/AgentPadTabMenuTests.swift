import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class AgentPadTabMenuTests: XCTestCase {
    func testPlusOpensAgentPickerEvenWhenDefaultIsSelected() throws {
        let store = makeTestStore(), model = AgentPadSettingsModel.shared
        defer { store.terminate() }
        let savedDefault = model.defaultAgentId, savedHidden = model.hiddenAgents
        defer { model.defaultAgentId = savedDefault; model.hiddenAgents = savedHidden }
        model.hiddenAgents = []
        let workspace = try XCTUnwrap(store.active), pane = try XCTUnwrap(workspace.activePane)
        let original = pane.tabs.map(\.id)
        for defaultID in [String?.none, AgentTemplate.claudeCode.id, AgentTemplate.codex.id, AgentTemplate.terminal.id] {
            model.defaultAgentId = defaultID
            var open = false
            let button = AddTabButton(pane: pane, workspace: workspace, store: store,
                isMenuOpen: Binding(get: { open }, set: { open = $0 }))
            button.trigger.action()
            XCTAssertTrue(open, "the actual + action must open the picker for \(defaultID ?? "no default")")
            XCTAssertEqual(pane.tabs.map(\.id), original, "a click must wait for an agent choice")
        }
        let choices = AgentTemplate.visibleOrdered(model: model).map(\.id)
        for id in [AgentTemplate.terminal.id, AgentTemplate.claudeCode.id, AgentTemplate.codex.id] {
            XCTAssertTrue(choices.contains(id))
        }
    }

    func testActualTabPopoverHasBoundedWidthForEveryExportState() async throws {
        let store = makeTestStore()
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession)
        for agent in [AgentTemplate.claudeCode, .codex, .terminal] {
            tab.agent = agent
            let host = NSHostingView(rootView: menu(tab))
            let size = host.fittingSize
            XCTAssertGreaterThanOrEqual(size.width, 280, agent.title)
            XCTAssertLessThanOrEqual(size.width, 320, agent.title)
            XCTAssertGreaterThan(size.height, 200, "menu rows remain visible")
            if let output = ProcessInfo.processInfo.environment["AGENTPAD_TAB_MENU_CAPTURE"] {
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFront(nil)
                defer { window.contentView = nil; window.close() }
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent("menu-\(agent.rosterId).png"))
            }
        }
    }

    func testExportExplanationsAreShortAndWrapWithoutTruncation() {
        for problem in [AgentAnswerTranscript.Problem.unbound, .unverified, .changed, .remote,
                        .hookIdentity, .hookAncestry, .claudeSignature, .claudeTerminal, .claudeBackground,
                        .ambiguousClaude, .multiplexer, .processUnavailable, .foregroundMismatch] {
            XCTAssertLessThanOrEqual(problem.rawValue.count, 150)
            let host = NSHostingView(rootView: AgentAnswerMenuExplanation(problem: problem).frame(width: 280))
            let line = NSHostingView(rootView: Text("One line").font(Theme.display(11)).padding(8))
            XCTAssertGreaterThan(host.fittingSize.height, line.fittingSize.height, problem.rawValue)
            XCTAssertLessThan(host.fittingSize.height, 100, problem.rawValue)
        }
    }

    private func menu(_ tab: Session) -> AgentPadTabMenu {
        AgentPadTabMenu(tab: tab, canCloseToRight: false, dismiss: {}, onClose: {}, onCloseOthers: {},
            onCloseToRight: {}, onDuplicate: {}, onRename: {}, onSplit: { _ in }, onMoveToNewWindow: {}, onLastAnswer: { _ in })
    }
}
