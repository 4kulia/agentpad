import AppKit
import AgentPadQuietTestSupport
import CryptoKit
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

/// Exercise the actual shared Pins control beside the default native timeline.
/// Keep its public configuration, image captures and dispatched filter transitions;
/// the pre-switch legacy comparison is archived outside the product build.
@MainActor final class ChatNativePinsParityTests: XCTestCase {
    private var fixture: ChatChannelExecutionTests.Fixture!
    private var scope: TeamServiceTestScope!
    private var directory: URL!
    private var oldTeam: TeamService?
    private var oldOrg: ChatOrgCurrent?
    private var oldBadge: (@MainActor () -> Void)!
    private var oldActive: (@MainActor () -> Bool)!
    private var oldTheme: (AgentPadAppearanceMode, String, String, Bool)!
    private var oldEnhanced: Any?

    override func setUp() async throws {
        guard APQuietIsEnabled() else { throw ChatTimelineParityLayout.failure("Quiet harness required") }
        ChatScrollAppKitSettings.install(); AgentPadFonts.registerOnce(); _ = NSApplication.shared
        scope = TeamServiceTestScope()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-pins-" + UUID().uuidString)
        ChatStubProtocol.reset { _, _ in .failure(URLError(.unsupportedURL)) }
        fixture = try await ChatChannelExecutionTests.Fixture(root: directory)
        oldTeam = TeamService.sharedForTesting; oldOrg = ChatOrgCurrent.sharedForTesting
        oldBadge = ChatNotifications.badgeChanged
        oldActive = ChatNotifications.appActive
        TeamService.sharedForTesting = fixture.teamService; ChatOrgCurrent.sharedForTesting = fixture.service.orgCurrent
        ChatNotifications.badgeChanged = {}; ChatNotifications.appActive = { false }
        let settings = AgentPadSettingsModel.shared
        oldTheme = (settings.appearanceMode, settings.lightTerminalThemeSelection,
            settings.darkTerminalThemeSelection, settings.pairedThemeSchemaEnabled)
        settings.prepareFirstLaunchAppearance()
        settings.lightTerminalThemeSelection = AgentPadSettingsModel.defaultLightThemeSelection
        settings.darkTerminalThemeSelection = AgentPadSettingsModel.defaultDarkThemeSelection
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        oldEnhanced = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
    }

    override func tearDown() async throws {
        guard fixture != nil else {
            scope?.close(); ChatStubProtocol.reset()
            if let directory { try? FileManager.default.removeItem(at: directory) }
            XCTAssertNil(APQuietFailure())
            return
        }
        fixture.sender?.hold(); await fixture.service.disconnect()
        TeamService.sharedForTesting = oldTeam; ChatOrgCurrent.sharedForTesting = oldOrg
        ChatNotifications.badgeChanged = oldBadge; ChatNotifications.appActive = oldActive; ChatOrgCurrent.shared.refresh()
        let settings = AgentPadSettingsModel.shared
        if !oldTheme.3 { settings.load() }
        settings.appearanceMode = oldTheme.0; settings.lightTerminalThemeSelection = oldTheme.1
        settings.darkTerminalThemeSelection = oldTheme.2
        NSApp.accessibilitySetValue(oldEnhanced, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        scope.close(); ChatStubProtocol.reset(); fixture = nil
        try? FileManager.default.removeItem(at: directory)
        XCTAssertNil(APQuietFailure())
    }

    func testNativePinsPublicControlAndDispatchedAuthorFilters() async throws {
        let f = fixture!, channel = ChatTimelineReferenceFixture.channel, root = ChatTimelineReferenceFixture.root
        let agent = "w09-pins-agent", humanBody = "A channel message with **native text**.", agentBody = "W09 pinned agent answer."
        f.service.serverCapabilities[f.key.server] = ["chat.pins"]
        try f.write("UPDATE meta SET agents_served = 1")
        let bodies = [root: "A channel message with native text.", agent: agentBody]
        for (index, entry) in [(root, humanBody), (agent, agentBody)].enumerated() {
            try f.write("""
                INSERT INTO messages (message_id, channel_id, author_account_id, seq, created_at, has_fixed, has_mutable, text, mentions, revision)
                VALUES (?, ?, ?, ?, ?, 1, 1, ?, '[]', 3)
                """, [entry.0, channel, f.key.accountId, index + 1, ChatTimelineReferenceFixture.date, entry.1])
        }
        let human = ChatB1.PinnedMessage(messageId: root, seq: 1, authorAccountId: f.key.accountId,
            excerpt: "A channel message with native text.", pinnedBy: f.key.accountId, pinnedAt: ChatTimelineReferenceFixture.date)
        let bot = ChatB1.PinnedMessage(messageId: agent, seq: 2, authorAccountId: f.key.accountId,
            authorAgentId: "w09-agent", authorAgentName: "W09 Reviewer", excerpt: agentBody,
            pinnedBy: f.key.accountId, pinnedAt: ChatTimelineReferenceFixture.date)
        func pins(_ values: [ChatB1.PinnedMessage]) throws {
            try f.write("INSERT OR REPLACE INTO b1_pins (channel_id, data, dirty) VALUES (?, ?, 0)",
                [channel, try JSONEncoder().encode(values)])
        }
        let output = ProcessInfo.processInfo.environment["AGENTPAD_W09_PINS_EVIDENCE"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        var records: [[String: Any]] = []
        for dark in [false, true] {
            AgentPadSettingsModel.shared.appearanceMode = dark ? .dark : .light
            for width: CGFloat in [1040, 760, 420, 320] {
                try pins([human])
                let card = ChatChannelCard(channelId: channel, teamId: "f5000000-0000-4000-8000-000000000004",
                    name: "billing", createdBy: f.key.accountId, archived: false, version: 1)
                let sessions = [ChatChannelSession()]
                let models = try sessions.map { session in
                    session.update(.ready(card, team: "Billing", offline: true), key: f.key, store: f.store, service: f.service)
                    let model = try XCTUnwrap(session.model); model.pins.open(); return model
                }
                try ChatTimelineReferenceCapture.prepareOrganization(f.service)
                let hosts = sessions.map { session in
                    return ChatQuietHost(content: AnyView(ChatChannelView(card: card, team: "Billing", offline: true,
                        key: f.key, conversation: session, service: f.service)
                        .frame(width: width, height: 780).background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
                        .environment(\.locale, Locale.current).environment(\.timeZone, TimeZone.current)
                        .environment(\.colorScheme, dark ? .dark : .light)),
                        dark: dark, width: width, height: 780)
                }
                defer { hosts.forEach { $0.close() } }
                for host in hosts { try await host.settle(); try await host.settle() }
                let controls = try hosts.map { host in
                    let candidates = ChatTimelineReferenceCapture.descendants(host.view, NSSegmentedControl.self).filter { control in
                        (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" } == ["All", "Agents", "People"]
                    }
                    XCTAssertEqual(candidates.count, 1)
                    return try XCTUnwrap(candidates.first)
                }
                let id = "channel-pins-panel-\(Int(width))-\(dark ? "dark" : "light")"
                let initial = try recordControls(id: id, stage: "initial", hosts: hosts, controls: controls, output: output)
                XCTAssertEqual(models.map { $0.pins.filter }, [.all])
                try pins([human, bot])
                for host in hosts { try await host.settle(); try await host.settle() }
                var transitions: [[String: Any]] = []
                for (segment, filter, expected) in [(1, ChatPinFilter.agents, [agent]), (2, .people, [root]), (0, .all, [agent, root])] {
                    var actual: [[String]] = []
                    for index in hosts.indices {
                        let control = controls[index]
                        XCTAssertTrue(control.isEnabled(forSegment: segment))
                        APQuietSelectWindow(hosts[index].window)
                        control.selectedSegment = segment
                        let dispatched = control.sendAction(try XCTUnwrap(control.action), to: try XCTUnwrap(control.target))
                        XCTAssertTrue(dispatched)
                        try await hosts[index].settle(); try await hosts[index].settle()
                        XCTAssertEqual(models[index].pins.filter, filter, "The actual control action must update the owning model")
                        XCTAssertEqual(control.selectedSegment, segment)
                        let pane = try pinsPane(containing: control)
                        let texts = ChatTimelineReferenceCapture.descendants(pane, ChatMentionText.MessageTextView.self)
                            .filter { !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty }.map(\.string)
                        let visible = bodies.keys.filter { texts.contains(bodies[$0]!) }.sorted()
                        XCTAssertEqual(visible, expected.sorted(), "The mounted pinned-message list must filter its actual bodies")
                        actual.append(visible)
                    }
                    let observation = try recordControls(id: id, stage: filter.rawValue, hosts: hosts, controls: controls, output: output)
                    transitions.append(["filter": filter.rawValue, "segment": segment, "dispatched": true,
                        "modelFilters": models.map { $0.pins.filter.rawValue }, "selectedSegments": controls.map(\.selectedSegment),
                        "expectedVisibleIDs": expected.sorted(), "actualVisibleIDs": actual, "controls": observation])
                }
                let record: [String: Any] = ["id": id, "width": width, "dark": dark, "initial": initial, "transitions": transitions]
                records.append(record)
                let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                // Flush each complete record before XCTest emits its result on
                // stderr; buffered print output can split the final JSON line.
                FileHandle.standardOutput.write(Data("W09_PINS_CONTROL ".utf8) + bytes + Data("\n".utf8))
                if let output { try bytes.write(to: output.appendingPathComponent(id + ".json"), options: .withoutOverwriting) }
            }
        }
        XCTAssertEqual(records.count, 8)
    }

    private func pinsPane(containing control: NSSegmentedControl) throws -> NSView {
        var current: NSView = control
        while let parent = current.superview {
            if parent is NSSplitView { return current }
            current = parent
        }
        throw ChatTimelineParityLayout.failure("The actual Pins control is not in a mounted split-view pane")
    }

    private func recordControls(id: String, stage: String, hosts: [ChatQuietHost], controls: [NSSegmentedControl], output: URL?) throws -> [String: Any] {
        let values = try hosts.indices.map { try configuration(controls[$0], in: hosts[$0]) }
        XCTAssertEqual(controls.count, 1)
        let control = try XCTUnwrap(controls.first)
        XCTAssertEqual((0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }, ["All", "Agents", "People"])
        XCTAssertEqual((0..<control.segmentCount).map { control.isSelected(forSegment: $0) },
            (0..<control.segmentCount).map { $0 == control.selectedSegment })
        XCTAssertTrue(control.isEnabled)
        var images: [ChatTimelineParity.Raster] = [], evidence: [[String: Any]] = []
        for index in hosts.indices {
            let host = hosts[index], control = controls[index]
            XCTAssertTrue(control.window === host.window && control.isDescendant(of: host.view),
                "Evidence must observe the currently mounted control")
            APQuietSelectWindow(host.window)
            let whole = try ChatTimelineCaptureColor.bitmap(host.view)
            let rect = ChatTimelineParityLayout.frame(control.bounds, from: control, in: host.view)
            let scale = CGFloat(whole.pixelsWide) / host.view.bounds.width
            let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            XCTAssertEqual(pixels, pixels.integral, "The zero-margin crop must use the exact observed control frame")
            let image = NSBitmapImageRep(cgImage: try XCTUnwrap(whole.cgImage?.cropping(to: pixels)))
            let raster = try ChatTimelineParity.Raster(image); images.append(raster)
            let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
            var info: [String: Any] = ["controlFrame": NSStringFromRect(rect), "pixelBox": NSStringFromRect(pixels),
                "pixelWidth": raster.width, "pixelHeight": raster.height,
                // Raster converts to sRGB; the untouched PNG retains the frozen
                // Display profile. Bind both representations without retagging.
                "canonicalRasterRGBASHA256": SHA256.hash(data: Data(raster.rgba)).map { String(format: "%02x", $0) }.joined(),
                "canonicalRasterEncoding": "sRGB-RGBA8-straight-alpha",
                "pngSHA256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
                "iccProfileSHA256": SHA256.hash(data: try XCTUnwrap(image.colorSpace.iccProfileData))
                    .map { String(format: "%02x", $0) }.joined()]
            if let output {
                let path = output.appendingPathComponent(id + "-" + stage + "-native.png")
                try png.write(to: path, options: .withoutOverwriting)
                info["path"] = path.path
            }
            evidence.append(info)
        }
        XCTAssertGreaterThan(images[0].width, 0); XCTAssertGreaterThan(images[0].height, 0)
        return ["nativeConfiguration": values[0], "images": evidence]
    }

    private func configuration(_ control: NSSegmentedControl, in host: ChatQuietHost) throws -> [String: Any] {
        let font = try XCTUnwrap(control.font)
        let cell = try XCTUnwrap(control.cell)
        let children = ChatTimelineReferenceCapture.accessibilityAttribute(cell, "accessibilityChildren") as? [NSObject] ?? []
        let segmentFrames = try children.map { child -> String in
            let screen = try XCTUnwrap(child.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            let local = host.view.convert(host.window.convertFromScreen(screen), from: nil)
            return NSStringFromRect(CGRect(x: local.minX - host.view.bounds.minX,
                y: host.view.isFlipped ? local.minY - host.view.bounds.minY : host.view.bounds.maxY - local.maxY,
                width: local.width, height: local.height))
        }
        XCTAssertEqual(children.count, 3)
        return ["font": ["family": font.familyName ?? "", "name": font.fontName, "size": font.pointSize,
            "symbolicTraits": font.fontDescriptor.symbolicTraits.rawValue,
            "traits": (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: NSNumber] ?? [:])
                .reduce(into: [String: NSNumber]()) { $0[$1.key.rawValue] = $1.value }],
            "frame": NSStringFromRect(ChatTimelineParityLayout.frame(control.bounds, from: control, in: host.view)),
            "bounds": NSStringFromRect(control.bounds), "segmentFrames": segmentFrames,
            "style": control.segmentStyle.rawValue, "distribution": control.segmentDistribution.rawValue,
            "controlSize": control.controlSize.rawValue, "selectedSegment": control.selectedSegment,
            "enabled": control.isEnabled, "segmentCount": control.segmentCount,
            "segments": (0..<control.segmentCount).map { index in
                ["label": control.label(forSegment: index) ?? "", "enabled": control.isEnabled(forSegment: index),
                 "selected": control.isSelected(forSegment: index), "width": control.width(forSegment: index)] as [String: Any]
            }]
    }
}
