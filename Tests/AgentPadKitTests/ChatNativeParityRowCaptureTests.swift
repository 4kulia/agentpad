import AppKit
import AgentPadQuietTestSupport
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

/// Shared picker content versus the native action bridge.
/// Historical live legacy row-owned popup pairs are archived outside the build.
@MainActor final class ChatNativeParityRowCaptureTests: XCTestCase {
    private typealias P = ChatNativeMetadataParity
    private var captureCase = "setup"
    private var capturePhase = "setup"
    private var captureRenderer = "pair"

    func testW09ReactionPickerAgainstActualLegacyThreeCheckGate() async throws {
        try await pickerPairs()
    }

    private func pickerPairs() async throws {
        guard ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_W09_CAPTURE"] == "1" else {
            throw XCTSkip("Set AGENTPAD_CHAT_NATIVE_W09_CAPTURE=1 to record W09 picker pairs")
        }
        XCTAssertTrue(APQuietIsEnabled())
        ChatScrollAppKitSettings.install(); AgentPadFonts.registerOnce(); _ = NSApplication.shared
        let output = try ChatTimelineReferencePaths.root(XCTUnwrap(ProcessInfo.processInfo.environment["AGENTPAD_CHAT_PARITY_EVIDENCE"]))
            .appendingPathComponent("w09-picker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scratch = output.appendingPathComponent("fixture")
        let scope = TeamServiceTestScope()
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhanced = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        let themes = AgentPadTerminalTheme.ghosttyUserThemesDirectory().standardizedFileURL
        let quietRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build").standardizedFileURL
        guard themes.path.hasPrefix(quietRoot.path + "/quiet-xctest-") else {
            throw ChatTimelineParityLayout.failure("Picker fixture requires its own quiet sandbox theme directory")
        }
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        let settingsURL = AgentPadSettings.url.standardizedFileURL
        guard settingsURL.path.hasPrefix(quietRoot.path + "/quiet-xctest-") else {
            throw ChatTimelineParityLayout.failure("Picker fixture requires its own quiet sandbox settings file")
        }
        let hadSettingsFile = FileManager.default.fileExists(atPath: settingsURL.path)
        if !hadSettingsFile {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: settingsURL, options: .withoutOverwriting)
        }
        let settings = AgentPadSettingsModel.shared
        let previousTheme = (settings.appearanceMode, settings.lightTerminalThemeSelection,
            settings.darkTerminalThemeSelection, settings.pairedThemeSchemaEnabled)
        settings.prepareFirstLaunchAppearance()
        settings.lightTerminalThemeSelection = AgentPadSettingsModel.defaultLightThemeSelection
        settings.darkTerminalThemeSelection = AgentPadSettingsModel.defaultDarkThemeSelection
        let oldTeam = TeamService.sharedForTesting, oldOrg = ChatOrgCurrent.sharedForTesting
        let oldBadge = ChatNotifications.badgeChanged
        ChatNotifications.badgeChanged = {}
        defer {
            TeamService.sharedForTesting = oldTeam; ChatOrgCurrent.sharedForTesting = oldOrg; ChatOrgCurrent.shared.refresh()
            ChatNotifications.badgeChanged = oldBadge; ChatStubProtocol.reset(); scope.close()
            NSApp.accessibilitySetValue(previousEnhanced, forAttribute: enhanced)
            if !previousTheme.3 { settings.load() }
            settings.appearanceMode = previousTheme.0; settings.lightTerminalThemeSelection = previousTheme.1
            settings.darkTerminalThemeSelection = previousTheme.2
            if !hadSettingsFile { try? FileManager.default.removeItem(at: settingsURL) }
            try? FileManager.default.removeItem(at: scratch)
        }
        ChatStubProtocol.reset { _, _ in .failure(URLError(.unsupportedURL)) }
        let fixture = try await ChatChannelExecutionTests.Fixture(root: scratch)
        TeamService.sharedForTesting = fixture.teamService; ChatOrgCurrent.sharedForTesting = fixture.service.orgCurrent
        do {
            capturePhase = "fixture-connect"
            let transport = try await connect(fixture)
            // The capture matrix outlives two advertised heartbeats. Keep the
            // fixture server alive through the normal protocol, just as a real
            // connected server does; do not extend the socket's timeout.
            let heartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    transport.frame(#"{"frame":"ping"}"#)
                }
            }
            defer { heartbeat.cancel() }
            let states = ["empty", "valid-entry", "invalid-entry", "pending", "failure", "archived"]
            let themes = [false, true]
            let widths = ChatNativeParityCaptureWidths.standard
            let expectedPairs = 24
            var captured: [String] = []
            for dark in themes {
                settings.appearanceMode = dark ? .dark : .light
                for width in widths {
                    for state in states {
                        let id = "picker-\(state)-\(Int(width))-\(dark ? "dark" : "light")"
                        captureCase = id; capturePhase = "fixture-state"; captureRenderer = "pair"
                        guard fixture.service.socket?.state == .connected else {
                            throw ChatTimelineParityLayout.failure("Picker fixture server lost its connection before " + id)
                        }
                        let message = try ChatTimelineReferenceFixture.message(id, me: fixture.key.accountId)
                        try seed(fixture, message: message, pending: state == "pending", startArchived: true)
                        let b1 = ChatB1Channel(key: fixture.key, channel: message.channelId, store: fixture.store, service: fixture.service)
                        if state == "failure" { b1.toggle(message.id, emoji: "invalid") }
                        XCTAssertTrue(b1.state.accessible)
                        XCTAssertEqual(b1.canChange, !pickerArchived(state))
                        XCTAssertEqual(b1.pending(message.id, choice: "👍"), state == "pending")
                        XCTAssertEqual(b1.problem(message.id), state == "failure" ? "Choose one emoji." : nil)
                        let model = ChatTimelineReferenceModel(fixture, messages: [message]); model.b1 = b1
                        let actions = ChatTimelineActions(model: model, root: nil,
                            conversation: ChatTimelineAdapter.conversation(model, root: nil))
                        actions.update(archived: pickerArchived(state), mentionable: [])
                        defer { actions.invalidate(); b1.hide() }
                        let nativeBody = try XCTUnwrap(actions.reactionPicker(messageID: message.id),
                            "The real row action bridge must supply the production picker")
                        let entry = state == "valid-entry" ? "🎉" : state == "invalid-entry" ? "two words" : state == "pending" ? "👍" : ""
                        try await capture(id: id, state: state, entry: entry, b1: b1,
                            legacy: AnyView(ChatReactionPicker(b1: b1, message: message.id)), native: nativeBody,
                            width: width, dark: dark, output: output)
                        captured.append(id)
                    }
                }
            }
            XCTAssertEqual(captured.count, expectedPairs)
            XCTAssertEqual(Set(captured).count, expectedPairs)
            let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            XCTAssertEqual(files.filter { $0.pathExtension == "png" }.count, expectedPairs * 2)
            XCTAssertEqual(files.filter { $0.pathExtension == "json" }.count, expectedPairs)
            try JSONSerialization.data(withJSONObject: ["states": states, "widths": widths, "themes": themes.map { $0 ? "dark" : "light" },
                "diagnosticOnly": false, "completeMatrix": true,
                "expectedPairs": expectedPairs,
                "recordedPairs": captured.count,
                "pairIDs": captured,
                "originalOwnerTransitions": 0,
                "fixtureServerPongs": transport.sent.filter { $0 == #"{"frame":"pong"}"# }.count,
                "referenceRegenerated": false, "placementCompared": false], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("run-selection.json"), options: .withoutOverwriting)
        } catch {
            // Preserve the actual error before session teardown can obscure it.
            let original = error as NSError
            let record: [String: Any] = ["case": captureCase, "phase": capturePhase, "renderer": captureRenderer,
                "rowOwned": false, "originalErrorType": String(reflecting: type(of: error)),
                "domain": original.domain, "code": original.code, "description": original.localizedDescription]
            do {
                let directory = output.appendingPathComponent("diagnostics")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("picker-original-error.json"), options: .atomic)
            } catch { print("W09_PICKER_ERROR_RECORD_FAILED: \(error)") }
            await fixture.service.disconnect(); throw error
        }
        await fixture.service.disconnect()
    }

    private func capture(id: String, state: String, entry: String, b1: ChatB1Channel,
                         legacy leftBody: AnyView, native rightBody: AnyView, width: CGFloat, dark: Bool, output: URL) async throws {
        func plain(_ body: AnyView) -> AnyView {
            AnyView(VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 24)
                body.chatParity("externalContent", "row")
                Spacer(minLength: 0)
            }.frame(width: width, height: 600, alignment: .topLeading))
        }
        func styled(_ body: AnyView) -> AnyView {
            AnyView(body.background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.timeZone, TimeZone(identifier: "Europe/Amsterdam")!)
                .environment(\.colorScheme, dark ? .dark : .light))
        }
        let left = plain(leftBody), right = plain(rightBody)
        let leftMeasured = ChatTimelineParityLayout.legacy(content: left), rightMeasured = ChatTimelineParityLayout.legacy(content: right)
        let mode = ChatW09ProbeMode()
        let leftView = NSHostingView<AnyView>(rootView: styled(AnyView(ChatW09ProbeEnvironment(content: left, mode: mode, includeViewport: true))))
        let rightView = NSHostingView<AnyView>(rootView: styled(rightMeasured.content))
        let legacy = ChatQuietHost(view: leftView, dark: dark, width: width, height: 600)
        let native = ChatQuietHost(view: rightView, dark: dark, width: width, height: 600)
        defer { legacy.close(); native.close() }
        for host in [legacy, native] {
            try await host.settle()
            try await setEntry(entry, host: host)
        }
        captureRenderer = "legacy"
        let legacyControls = try controls(legacy, state: state)
        captureRenderer = "native"
        let nativeControls = try controls(native, state: state)
        XCTAssertEqual(legacyControls, nativeControls, "Actual picker labels, exact AX frames and enabled states")
        let current = try ChatNativeW09CaptureAX.appending(legacyControls.map(\.element), to: leftMeasured.collector.snapshot(in: legacy.view))
        let candidate = try ChatNativeW09CaptureAX.appending(nativeControls.map(\.element), to: rightMeasured.collector.snapshot(in: native.view))
        APQuietSelectWindow(legacy.window); let expected = try P.bitmap(legacy.view)
        APQuietSelectWindow(native.window); let actual = try P.bitmap(native.view)
        // Disabling the capture environment restores the original title-based
        // Button constructors in the same picker, preserving its field state.
        let observedFrame = legacy.window.frame, observedBounds = legacy.view.bounds
        let observedAX = legacy.strings
        mode.enabled = false
        try await legacy.settle()
        let cleanProbeCount = ChatTimelineReferenceCapture.descendants(legacy.view, ChatTimelineParityProbeView.self).count
        let clean = try P.bitmap(legacy.view)
        let neutrality = ChatTimelineParity.bitmap(try .init(expected), try .init(clean))
        let cleanControls = try controls(legacy, state: state, includeDrawing: false), cleanAX = legacy.strings
        let controlsUnchanged = controlFacts(cleanControls) == controlFacts(legacyControls)
        let axUnchanged = cleanAX == observedAX
        let geometryUnchanged = legacy.window.frame == observedFrame && legacy.view.bounds == observedBounds
        XCTAssertEqual(cleanProbeCount, 0)
        XCTAssertEqual(legacy.window.frame, observedFrame)
        XCTAssertEqual(legacy.view.bounds, observedBounds)
        XCTAssertEqual(controlFacts(cleanControls), controlFacts(legacyControls), "Original picker constructors must retain exact control AX facts")
        XCTAssertEqual(cleanAX, observedAX, "Original picker constructors must retain the complete exposed string state")
        XCTAssertEqual(neutrality.differentPixels, 0, "Original picker constructors changed production pixels")
        try P.record(id: id, testName: name, inventory: ["R29"], current: current, candidate: candidate,
            expected: expected, actual: actual,
            fixture: ["state": state, "entry": entry, "canChange": b1.canChange, "accessible": b1.state.accessible,
                "nativeContent": "ChatTimelineActions.reactionPicker → ChatNativeReactionPicker"],
            observations: ["legacyControls": try P.json(legacyControls), "nativeControls": try P.json(nativeControls),
                "requiredBranchesVerified": legacyControls == nativeControls,
                "instrumentationNeutral": neutrality.differentPixels == 0 && cleanProbeCount == 0
                    && controlsUnchanged && axUnchanged && geometryUnchanged,
                "instrumentationPixels": try P.json(neutrality), "cleanProbeCount": cleanProbeCount,
                "originalConstructorControls": try P.json(cleanControls), "originalConstructorAX": cleanAX,
                "observedAX": observedAX, "instrumentationControlsUnchanged": controlsUnchanged,
                "instrumentationAXUnchanged": axUnchanged, "instrumentationGeometryUnchanged": geometryUnchanged,
                "pickerTextUsesDrawingObservations": true, "contentPixels": true,
                "placementCertified": false, "popupLifecycleEvidence": "ChatNativeServiceActionTests.testNativePinMenuAndReactionPickerDispatchRealCommandsWithCurrentGuards"],
            output: output)
        XCTAssertNil(APQuietFailure())
    }

    // Probe removal intentionally removes typography observations. Compare the
    // complete AX contract (identity/title/frame/enabled) independently; the
    // existing paired drawing/typography comparison above remains unchanged.
    private func controlFacts(_ observations: [ChatNativeW09CaptureAX.Observation]) -> [ChatNativeW09CaptureAX.Observation] {
        observations.filter { !["w09/picker/title", "w09/picker/problem"].contains($0.id) }
            .map { .init(id: $0.id, title: $0.title, frame: $0.frame, enabled: $0.enabled) }
    }

    private func setEntry(_ entry: String, host: ChatQuietHost) async throws {
        APQuietSelectWindow(host.window)
        let field = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host.view, NSTextField.self)
            .first { $0.placeholderString == "Emoji" })
        if field.stringValue != entry {
            XCTAssertTrue(host.window.makeFirstResponder(field))
            field.stringValue = entry
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            try await host.settle()
        }
        guard field.stringValue == entry else { throw ChatTimelineParityLayout.failure("Actual picker entry differs from the requested state") }
        XCTAssertTrue(host.window.makeFirstResponder(nil))
        try await host.settle()
    }

    private func pickerArchived(_ state: String) -> Bool {
        state == "archived" || state == "archived-denied-action"
    }

    private func pickerProblem(_ state: String) -> String? {
        switch state {
        case "failure": "Choose one emoji."
        case "archived-denied-action": ChatError.storage("Connect to change reactions or pins.").localizedDescription
        default: nil
        }
    }

    private func verifyDeniedQuickControls(_ controls: [ChatNativeW09CaptureAX.Observation], native: Bool) throws {
        let quickIDs = ["👍", "❤️", "😂", "🎉", "✨", "👀"].map { "w09/picker/quick/" + $0 }
        let quick = controls.filter { quickIDs.contains($0.id) }
        XCTAssertEqual(quick.map(\.id), quickIDs)
        let vector = quick.map(\.enabled)
        let disabled: [Bool?] = Array(repeating: false, count: 6)
        let enabled: [Bool?] = Array(repeating: true, count: 6)
        guard vector == disabled || (!native && vector == enabled),
              controls.first(where: { $0.id == "w09/picker/add" })?.enabled == false,
              controls.first(where: { $0.id == "w09/picker/palette" })?.enabled == true else {
            throw ChatTimelineParityLayout.failure("Denied archive must disable every native quick action and Add; legacy retains its observed uniform quick vector")
        }
    }

    private func controls(_ host: ChatQuietHost, state: String, includeDrawing: Bool = true) throws -> [ChatNativeW09CaptureAX.Observation] {
        let quick = ["👍", "❤️", "😂", "🎉", "✨", "👀"]
        XCTAssertEqual(ChatEmoji.quick, quick)
        var result: [ChatNativeW09CaptureAX.Observation] = []
        capturePhase = "observe-title"
        if includeDrawing {
            result.append(try ChatNativeW09CaptureAX.observedProbeText("Add reaction", id: "w09/picker/title", host: host))
        }
        for emoji in quick {
            capturePhase = "observe-quick-" + emoji
            let control = try ChatNativeW09CaptureAX.observe(emoji, id: "w09/picker/quick/" + emoji, host: host, button: true)
            guard state == "archived-denied-action"
                    || control.enabled == (!pickerArchived(state) && !(state == "pending" && emoji == "👍")) else {
                throw ChatTimelineParityLayout.failure("Picker quick reaction has the wrong enabled state: " + emoji)
            }
            result.append(control)
        }
        capturePhase = "observe-field"
        result.append(try ChatNativeW09CaptureAX.observedField("Choose or paste one emoji", id: "w09/picker/field", host: host))
        capturePhase = "observe-palette"
        let palette = try ChatNativeW09CaptureAX.observe("Emoji & Symbols", id: "w09/picker/palette", host: host, button: true)
        guard palette.enabled == true else { throw ChatTimelineParityLayout.failure("Picker palette must remain enabled") }
        result.append(palette)
        capturePhase = "observe-add"
        let add = try ChatNativeW09CaptureAX.observe("Add", id: "w09/picker/add", host: host, button: true)
        guard add.enabled == (state == "valid-entry") else { throw ChatTimelineParityLayout.failure("Picker Add has the wrong enabled state") }
        result.append(add)
        if let problem = pickerProblem(state), includeDrawing {
            capturePhase = "observe-problem"
            result.append(try ChatNativeW09CaptureAX.observedProbeText(problem, id: "w09/picker/problem", host: host))
        }
        if state == "archived-denied-action" {
            try verifyDeniedQuickControls(result, native: captureRenderer == "native")
        }
        XCTAssertEqual(result.count, includeDrawing ? (pickerProblem(state) != nil ? 11 : 10) : 9)
        return result
    }

    private func seed(_ f: ChatChannelExecutionTests.Fixture, message: ChatMessage, pending: Bool, startArchived: Bool = true) throws {
        f.service.serverCapabilities[f.key.server] = ["chat.reactions"]
        f.service.isServerKnown = { _, _ in true }
        let archived = startArchived && message.id.contains("picker-archived-")
        let metadata = ChatB1.Metadata(messageId: message.id, deleted: false, reactions: [], pin: nil)
        try f.store.queue.write { db in
            try db.execute(sql: "DELETE FROM b1_intents")
            try db.execute(sql: "DELETE FROM b1_metadata")
            try db.execute(sql: "UPDATE channels SET archived = ? WHERE channel_id = ?", arguments: [archived, message.channelId])
            try ChatB1.watch(db, channel: message.channelId, ids: [message.id])
            try db.execute(sql: "UPDATE b1_metadata SET data = ?, dirty = 0, as_of_seq = 3 WHERE message_id = ?",
                arguments: [try JSONEncoder().encode(metadata), message.id])
            if pending {
                let command = ChatCommandRecord(commandId: message.id, sessionId: "s-anna", type: "message.reaction.set",
                    bodyBytes: Data(), orderKey: message.id, createdAt: Date(timeIntervalSince1970: 1), state: .pending)
                try command.insert(db)
                try db.execute(sql: "INSERT INTO b1_intents (command_id, channel_id, message_id, choice, present) VALUES (?, ?, ?, '👍', 1)",
                    arguments: [command.commandId, message.channelId, message.id])
            }
        }
    }

    private func connect(_ f: ChatChannelExecutionTests.Fixture) async throws -> FakeSocketTransport {
        let transport = FakeSocketTransport()
        f.service.makeSocketTransport = { transport }
        ChatStubProtocol.reset { request, _ in
            guard request.url?.path == "/v1/server" else { return .failure(URLError(.unsupportedURL)) }
            return .success(.init(status: 200, body: Data(#"{"name":"fixture","version":"0.1.0","generation":"g1","api_versions":["v1"],"capabilities":["auth.email_code","events.ws","chat.channels","chat.reactions"]}"#.utf8)))
        }
        f.service.followsFeed = true
        try await f.service.start(mode: .server)
        let socket = try XCTUnwrap(f.service.socket); socket.lifecycle = nil
        let deadline = ContinuousClock.now + .seconds(3)
        while transport.request == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        _ = try XCTUnwrap(transport.request)
        transport.push(.opened)
        transport.frame(#"{"frame":"hello","generation":"g1","heartbeat_seconds":25,"version":"0.1.0"}"#)
        while socket.state != .connected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(socket.state, .connected)
        f.service.orgSessions[f.key]?.snapshotOwed = false
        f.service.orgSessions[f.key]?.outbox?.hold()
        return transport
    }
}
