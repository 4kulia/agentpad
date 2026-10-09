import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class AttentionSessionsSnapshotTests: XCTestCase {
    func testContactAvatarNativeSnapshots() async throws {
        guard let output = ProcessInfo.processInfo.environment["AGENTPAD_ATTENTION_CAPTURE"] else { throw XCTSkip("Native snapshots are opt-in") }
        _ = NSApplication.shared
        let appearance = AgentPadSettingsModel.shared.appearanceMode
        defer { AgentPadSettingsModel.shared.appearanceMode = appearance }
        let ids = ["palette-27", "palette-0", "palette-1", "palette-2", "palette-3", "palette-4",
                   "palette-5", "palette-6", "palette-7", "palette-19", "palette-18", "palette-26"]
        for dark in [false, true] {
            AgentPadSettingsModel.shared.appearanceMode = dark ? .dark : .light
            let view = VStack(alignment: .leading, spacing: 22) {
                Text("People and agents").font(Theme.display(18, weight: .semibold))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 18) {
                    ForEach(ids, id: \.self) { id in
                        HStack(spacing: 8) {
                            ContactAvatar(stableID: id, name: "Élodie", kind: .person, size: 38)
                            ContactAvatar(stableID: id, name: "reviewer", kind: .agent, size: 38)
                        }
                    }
                }
                HStack(spacing: 16) {
                    ContactAvatar(stableID: "acc_01J7VQ3A9KA0", name: "Alex Kim", kind: .person)
                    Text("Alex Kim · Design")
                    ContactAvatar(stableID: "acc_01J9C0F4T8AT", name: "Alex Kim", kind: .person)
                    Text("Alex Kim · Infra")
                    ChatAvatar(identity: .init(account: "owner", agent: "agt_4QH2N8AA", session: nil), name: "reviewer")
                    Text("reviewer")
                }.font(Theme.display(12))
            }.padding(24).frame(width: 720, height: 290).background(Theme.chromeBackground).foregroundStyle(Theme.chromeForeground)
            try await capture(view, output: output, name: "avatars-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    func testAllSessionsNativeSnapshots() async throws {
        guard let output = ProcessInfo.processInfo.environment["AGENTPAD_ATTENTION_CAPTURE"] else { throw XCTSkip("Native snapshots are opt-in") }
        _ = NSApplication.shared
        let appearance = AgentPadSettingsModel.shared.appearanceMode
        defer { AgentPadSettingsModel.shared.appearanceMode = appearance }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-snapshots-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try SessionStoreFixtures.writeFile("fixture.jsonl", in: root, lines: [
            #"{"type":"user","message":{"content":"Keep the settings spacing consistent."}}"#,
            #"{"type":"assistant","message":{"content":"The sidebar now uses the same spacing in both themes. Keyboard focus stays visible."}}"#,
            #"{"type":"user","message":{"content":"Run the targeted tests and show the result."}}"#
        ])
        let titles = ["Align spacing in Settings", "Check tab keyboard navigation", "Fix the import preview", "Add an empty search state", "Review sidebar variants"]
        let records = titles.enumerated().map { index, title in
            AgentSessionRecord(agentId: index.isMultiple(of: 2) ? "claude-code" : "codex", conversationId: "session-\(index)",
                title: title, cwd: URL(fileURLWithPath: "/Users/demo/atelier"), lastActivity: Date().addingTimeInterval(Double(-index * 1800)), fileURL: file)
        }
        for dark in [false, true] {
            AgentPadSettingsModel.shared.appearanceMode = dark ? .dark : .light
            for scenario in ["list", "empty", "scanning", "resume-error"] {
                let rows = scenario == "empty" ? [] : records
                let catalog = SessionCatalog { progress in
                    if scenario == "scanning" {
                        progress(.init(records: [], scanned: 0, total: 2171, skipped: 0))
                        Thread.sleep(forTimeInterval: 1.5)
                    }
                    return .init(records: rows, scanned: rows.count, total: rows.count, skipped: 0)
                }
                let model = AllSessionsModel(state: TabState(route: .allSessions), catalog: catalog, names: SessionNames(url: root.appendingPathComponent("names.sqlite")))
                model.visibility = { .init(channelIds: []) }
                await model.start()
                if scenario != "scanning" {
                    for _ in 0..<200 where catalog.isScanning { try await Task.sleep(for: .milliseconds(10)) }
                    model.refilter()
                    for _ in 0..<200 where model.result.total != rows.count { try await Task.sleep(for: .milliseconds(10)) }
                }
                if scenario == "list" { model.select(model.result.items.first) }
                if scenario == "resume-error" { model.resumeError = "The launch options for 'codex' disable session persistence, so the conversation could not be resumed." }
                let view = AllSessionsTab(model: model, autoload: false, liveSnapshot: { [] }).frame(width: 1000, height: 660)
                try await capture(view, output: output, name: "sessions-\(scenario)-\(dark ? "dark" : "light")", dark: dark)
                for _ in 0..<200 where catalog.isScanning { try await Task.sleep(for: .milliseconds(10)) }
                model.stop()
            }
        }
    }

    func testAttentionNativeSnapshots() async throws {
        guard let output = ProcessInfo.processInfo.environment["AGENTPAD_ATTENTION_CAPTURE"] else {
            throw XCTSkip("Native snapshots are opt-in")
        }
        _ = NSApplication.shared
        let appearance = AgentPadSettingsModel.shared.appearanceMode
        defer { AgentPadSettingsModel.shared.appearanceMode = appearance }
        let rows = [
            AttentionItem(id: "1", tier: 0, time: .now, title: "Release assistant", subtitle: "Call waits for your approval", action: .event("1"), subjectID: "agent-1", subjectName: "Release assistant", subjectIsAgent: true),
            AttentionItem(id: "2", tier: 1, time: .now, title: "Fix keyboard navigation", subtitle: "An agent needs your input", action: .event("2"), subjectID: "agent-2", subjectName: "Claude Code", subjectIsAgent: true),
            AttentionItem(id: "3", tier: 2, time: .now, title: "Build failed", subtitle: "A run or operation failed", action: .event("3"), secondary: .dismiss),
            AttentionItem(id: "4", tier: 3, time: .now, title: "#release", subtitle: "Mentioned you · 2 new", action: .event("4"), secondary: .markRead, subjectID: "person-1", subjectName: "Alex")
        ]
        for dark in [false, true] {
            AgentPadSettingsModel.shared.appearanceMode = dark ? .dark : .light
            for empty in [false, true] {
                let view = VStack(spacing: 0) {
                    AttentionSectionContent(items: empty ? [] : rows, collapsed: .constant(false), expanded: .constant(false),
                        activate: { _ in }, secondary: { _ in }, settings: {})
                    Text("Workspaces").font(.caption).foregroundStyle(.secondary).padding()
                    Spacer()
                }.frame(width: 280, height: 340).background(Theme.chromeBackground).foregroundStyle(Theme.chromeForeground)
                try await capture(view, output: output, name: "attention-\(empty ? "empty" : "reasons")-\(dark ? "dark" : "light")", dark: dark)
            }
        }
    }

    func capture(_ view: some View, output: String, name: String, dark: Bool) async throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        try bytes.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        XCTAssertGreaterThan(bytes.count, 500)
    }
}
