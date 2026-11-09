import AppKit
import AgentPadQuietTestSupport
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

/// Shared draft-button instrumentation remains independently testable after
/// the live legacy timeline comparison harness is archived outside the build.
@MainActor final class ChatNativeParityReviewTests: XCTestCase {
    private var fixture: ChatChannelExecutionTests.Fixture!
    private var scope: TeamServiceTestScope!
    private var scratch: URL!
    private var output: URL!
    private var oldTeam: TeamService?
    private var oldOrg: ChatOrgCurrent?
    private var oldBadge: (@MainActor () -> Void)!
    private var oldActive: (@MainActor () -> Bool)!
    private var oldTheme: (AgentPadAppearanceMode, String, String, Bool)!
    private var oldTime: Any?
    private var oldEnhanced: Any?

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_W09_CAPTURE"] == "1" else {
            throw XCTSkip("Set AGENTPAD_CHAT_NATIVE_W09_CAPTURE=1 for complete caller pairs")
        }
        for flag in ["AGENTPAD_CHAT_NATIVE_W06_CAPTURE", "AGENTPAD_CHAT_NATIVE_W07_CAPTURE"] {
            guard ProcessInfo.processInfo.environment[flag] == "1" else {
                throw ChatTimelineParityLayout.failure("W09 caller observations require " + flag + "=1")
            }
        }
        XCTAssertTrue(APQuietIsEnabled())
        ChatScrollAppKitSettings.install(); AgentPadFonts.registerOnce(); _ = NSApplication.shared
        let root = try ChatTimelineReferencePaths.root(try XCTUnwrap(ProcessInfo.processInfo.environment["AGENTPAD_CHAT_PARITY_EVIDENCE"]))
        output = root.appendingPathComponent("w09-callers-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("w09-callers-" + UUID().uuidString)
        scope = TeamServiceTestScope()
        ChatStubProtocol.reset { _, _ in .failure(URLError(.unsupportedURL)) }
        fixture = try await ChatChannelExecutionTests.Fixture(root: scratch)
        oldTeam = TeamService.sharedForTesting; oldOrg = ChatOrgCurrent.sharedForTesting
        oldBadge = ChatNotifications.badgeChanged; oldActive = ChatNotifications.appActive
        TeamService.sharedForTesting = fixture.teamService
        ChatOrgCurrent.sharedForTesting = fixture.service.orgCurrent
        ChatNotifications.badgeChanged = {}; ChatNotifications.appActive = { false }
        let settings = AgentPadSettingsModel.shared
        oldTheme = (settings.appearanceMode, settings.lightTerminalThemeSelection,
            settings.darkTerminalThemeSelection, settings.pairedThemeSchemaEnabled)
        settings.prepareFirstLaunchAppearance()
        settings.lightTerminalThemeSelection = AgentPadSettingsModel.defaultLightThemeSelection
        settings.darkTerminalThemeSelection = AgentPadSettingsModel.defaultDarkThemeSelection
        oldTime = UserDefaults.standard.object(forKey: "chat.ux2.alwaysShowTime")
        UserDefaults.standard.set(false, forKey: "chat.ux2.alwaysShowTime")
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        oldEnhanced = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
    }

    override func tearDown() async throws {
        guard fixture != nil else { return }
        fixture.sender?.hold(); await fixture.service.disconnect()
        TeamService.sharedForTesting = oldTeam; ChatOrgCurrent.sharedForTesting = oldOrg
        ChatNotifications.badgeChanged = oldBadge; ChatNotifications.appActive = oldActive
        ChatOrgCurrent.shared.refresh()
        let settings = AgentPadSettingsModel.shared
        if !oldTheme.3 { settings.load() }
        settings.appearanceMode = oldTheme.0; settings.lightTerminalThemeSelection = oldTheme.1
        settings.darkTerminalThemeSelection = oldTheme.2
        if let oldTime { UserDefaults.standard.set(oldTime, forKey: "chat.ux2.alwaysShowTime") }
        else { UserDefaults.standard.removeObject(forKey: "chat.ux2.alwaysShowTime") }
        NSApp.accessibilitySetValue(oldEnhanced, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        scope.close(); ChatStubProtocol.reset(); fixture = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Capture-only semantic-name omission must preserve the original drawing
    /// and action. Only the marker-free control certifies the production AX name.
    func testW09DraftDeleteObservationPreservesOriginalDrawingAndAction() async throws {
        let f = fixture!, channel = ChatTimelineReferenceFixture.channel
        try f.write("UPDATE channels SET archived = 1 WHERE channel_id = ?", [channel])
        f.service.serverCapabilities[f.key.server] = ["chat.attachments", "chat.attachments_context"]
        f.service.isServerKnown = { _, _ in true }
        let limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        f.service.serverAttachmentLimits[f.key.server] = limits
        let manager = try XCTUnwrap(f.service.attachments(f.key))
        let filename = "saved-delete-observation.txt", title = "Delete " + filename
        func seed() throws {
            try seedSavedFile(owner: .channel(channel), root: nil, name: filename, limits: limits,
                problem: "The channel is archived. Your file is saved locally.")
        }
        func control(_ host: ChatQuietHost, label: String) throws -> (node: NSObject, record: [String: Any]) {
            let candidates = host.nodes.filter { node in
                guard !(node is ChatTimelineParityProbeView),
                      ChatTimelineReferenceCapture.accessibilityAttribute(node, "accessibilityLabel") as? String == label,
                      let role = ChatTimelineReferenceCapture.accessibilityAttribute(node, "accessibilityRole") as? String else { return false }
                return ["AXButton", "AXLink"].contains(role) && node.responds(to: NSSelectorFromString("accessibilityPerformPress"))
            }
            guard candidates.count == 1 else {
                throw ChatTimelineParityLayout.failure("Missing unique original semantic Delete button: \(candidates.count)")
            }
            let node = candidates[0]
            let role = try XCTUnwrap(ChatTimelineReferenceCapture.accessibilityAttribute(node, "accessibilityRole") as? String)
            let screen = try XCTUnwrap(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            let local = host.view.convert(host.window.convertFromScreen(screen), from: nil)
            let frame = host.view.isFlipped ? local : CGRect(x: local.minX,
                y: host.view.bounds.height - local.maxY, width: local.width, height: local.height)
            let selector = NSSelectorFromString("accessibilityActionNames")
            let actions = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [String] ?? [] : []
            let enabledSelector = NSSelectorFromString("isAccessibilityEnabled")
            guard node.responds(to: enabledSelector) else {
                throw ChatTimelineParityLayout.failure("Semantic Delete button has no enabled observation")
            }
            typealias Enabled = @convention(c) (AnyObject, Selector) -> Bool
            let enabled = unsafeBitCast(node.method(for: enabledSelector), to: Enabled.self)(node, enabledSelector)
            let help = ChatTimelineReferenceCapture.accessibilityAttribute(node, "accessibilityHelp") as? String
            XCTAssertEqual(help, "Delete saved attachment")
            return (node, ["label": label, "role": role, "frame": NSStringFromRect(frame),
                "enabled": enabled, "actions": actions.sorted(), "help": help ?? ""])
        }
        func press(_ node: NSObject) throws -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard node.responds(to: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(node.method(for: selector), to: Press.self)(node, selector)
        }
        func recordNodes(_ host: ChatQuietHost, name: String) throws {
            let nodes: [[String: Any]] = host.nodes.map { node in
                var value: [String: Any] = ["class": String(reflecting: type(of: node)),
                    "respondsToPress": node.responds(to: NSSelectorFromString("accessibilityPerformPress"))]
                for attribute in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityRole"] {
                    if let string = ChatTimelineReferenceCapture.accessibilityAttribute(node, attribute) as? String {
                        value[attribute] = string
                    }
                }
                if node.responds(to: NSSelectorFromString("accessibilityFrame")),
                   let frame = node.value(forKey: "accessibilityFrame") as? NSValue {
                    value["screenFrame"] = NSStringFromRect(frame.rectValue)
                }
                return value
            }
            try JSONSerialization.data(withJSONObject: ["diagnosticOnly": true, "nodes": nodes],
                options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name + "-nodes.json"), options: .atomic)
        }
        do {
        try ChatTimelineReferenceCapture.prepareOrganization(f.service)
        for dark in [false, true] {
            AgentPadSettingsModel.shared.appearanceMode = dark ? .dark : .light
            for width in ChatNativeParityCaptureWidths.standard {
                try seed()
                func content(_ probes: Bool) -> AnyView {
                    AnyView(ChatAttachmentDraftStrip(manager: manager, owner: .channel(channel), root: nil, allowsRetry: false)
                        .frame(width: width, height: 140).background(ChatAppearance.surface)
                        .foregroundStyle(Theme.chromeForeground).environment(\.chatParityEnabled, probes)
                        .environment(\.colorScheme, dark ? .dark : .light))
                }
                let stem = "delete-source-\(Int(width))-\(dark ? "dark" : "light")"
                let root = NSHostingView(rootView: content(false))
                let host = ChatQuietHost(view: root, dark: dark, width: width, height: 140)
                defer { root.rootView = AnyView(EmptyView()); host.close() }
                try await host.settle()
                try recordNodes(host, name: stem + "-original")
                root.rootView = content(true); try await host.settle()
                try recordNodes(host, name: stem + "-observed")
                let observed = try control(host, label: "Delete")
                let draft = try XCTUnwrap(manager.files(owner: .channel(channel), root: nil).first)
                let drawing = try ChatNativeW09CaptureAX.observe("Delete",
                    id: "w09/caller/draft/" + draft.id + "/delete", host: host)
                guard let element = drawing.drawing, element.text == "Delete", element.textRuns?.isEmpty == false else {
                    throw ChatTimelineParityLayout.failure("The actual Delete title has no drawing operands")
                }
                let observedBitmap = try ChatTimelineCaptureColor.bitmap(host.view)
                root.rootView = content(false); try await host.settle()
                let original = try control(host, label: title)
                let originalBitmap = try ChatTimelineCaptureColor.bitmap(host.view)
                let neutrality = ChatTimelineParity.bitmap(try .init(originalBitmap), try .init(observedBitmap))
                var originalControl = original.record, observedControl = observed.record
                originalControl.removeValue(forKey: "label"); observedControl.removeValue(forKey: "label")
                let controlEqual = NSDictionary(dictionary: originalControl).isEqual(to: observedControl)
                let probesAbsent = ChatTimelineReferenceCapture.descendants(host.view, ChatTimelineParityProbeView.self).isEmpty
                XCTAssertEqual(neutrality.differentPixels, 0)
                XCTAssertTrue(controlEqual); XCTAssertTrue(probesAbsent)
                let originalPressed = try press(original.node)
                let originalRemoved = manager.files(owner: .channel(channel), root: nil).isEmpty
                XCTAssertTrue(originalPressed); XCTAssertTrue(originalRemoved)
                try seed(); root.rootView = content(true); try await host.settle()
                let mountedAgain = try control(host, label: "Delete")
                let observedPressed = try press(mountedAgain.node)
                let observedRemoved = manager.files(owner: .channel(channel), root: nil).isEmpty
                XCTAssertTrue(observedPressed); XCTAssertTrue(observedRemoved)
                try XCTUnwrap(originalBitmap.representation(using: .png, properties: [:])).write(
                    to: output.appendingPathComponent(stem + "-original.png"), options: .atomic)
                try XCTUnwrap(observedBitmap.representation(using: .png, properties: [:])).write(
                    to: output.appendingPathComponent(stem + "-observed.png"), options: .atomic)
                let record: [String: Any] = ["drawingNeutrality": neutrality.dimensionsMatch && neutrality.differentPixels == 0,
                    "dark": dark, "width": width, "originalSemanticControl": original.record,
                    "observedSemanticControl": observed.record, "sameRoleFrameEnabledHelpAndActions": controlEqual,
                    "observationScope": "capture-only omission of semantic name; production name verified independently",
                    "actualDrawing": try ChatNativeMetadataParity.json(element), "neutrality": try ChatNativeMetadataParity.json(neutrality),
                    "markerFreeOriginal": probesAbsent, "originalPressRemovedDraft": originalPressed && originalRemoved,
                    "observedPressRemovedDraft": observedPressed && observedRemoved]
                try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(
                    to: output.appendingPathComponent("delete-source-\(Int(width))-\(dark ? "dark" : "light").json"), options: .atomic)
            }
        }
        } catch {
            let original = error as NSError
            let failure: [String: Any] = ["diagnosticOnly": true, "originalErrorType": String(reflecting: type(of: error)),
                "domain": original.domain, "code": original.code, "description": original.localizedDescription]
            try JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted, .sortedKeys]).write(
                to: output.appendingPathComponent("delete-source-original-error.json"), options: .atomic)
            throw error
        }

    }

    private func seedSavedFile(owner: ChatAttachmentOwner, root: String?, name: String,
                               limits: ChatAttachmentLimits, problem: String) throws {
        let bytes = Data("Locally retained file fixture\n".utf8)
        var file = try ChatAttachmentStorage.descriptor(data: bytes, name: name, limits: limits)
        file.attachmentId = "f6000000-0000-4000-8001-000000000010"
        var draft = ChatAttachmentDraft(file: file, messageId: "w09-saved-file-post", owner: owner, root: root ?? "",
            session: "s-anna", generation: "g1", sha256: ChatAttachments.digest(bytes), createdAt: Date(timeIntervalSince1970: 1),
            expiresAt: Date().addingTimeInterval(3600), state: .failed)
        draft.problem = problem
        let manager = try XCTUnwrap(fixture.service.attachments(fixture.key))
        // The previous case removed its database row. Reconcile that deletion
        // before reusing the fixed fixture ID with exclusive local storage.
        manager.reconcile()
        try manager.storage.save(bytes, key: fixture.key, id: draft.id)
        try fixture.store.queue.write { try ChatAttachments.put($0, draft) }
        manager.reconcile()
        let saved = try XCTUnwrap(manager.files(owner: owner, root: root).first { $0.id == draft.id })
        XCTAssertEqual(saved.problem, problem)
        XCTAssertFalse(manager.canRetry(saved), "Read-only caller must expose local recovery without an upload retry")
    }

}
