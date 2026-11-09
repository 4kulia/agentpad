import AppKit
import AgentPadQuietTestSupport
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

/// Native timeline ownership regressions and comparisons for the shared popup
/// and request components that remain in use outside the message timeline.
/// Retired live legacy timeline captures are archived outside the build.
@MainActor final class ChatNativeMetadataCaptureTests: XCTestCase {
    private typealias S = NativeTimelineSnapshot
    private typealias P = ChatNativeMetadataParity
    func testNativeUnknownExecutionCaptionKeepsProviderState() async throws {
        let f = try await ChatNativeActionFixture()
        do {
            for width: CGFloat in [760, 420] {
                let model = ChatTimelineReferenceModel(f.base, messages: f.messages)
                model.threadRoot = f.messages[0].id
                model.threadRequests = [request("awaiting_vendor_response", fixture: f.base)]
                let host = ChatQuietHost(content: AnyView(ChatTimelineView(model: model, root: model.threadRoot,
                    members: [], mentionable: [], me: f.base.key.accountId, archived: false, ownerModel: nil)),
                    dark: false, width: width, height: 600)
                defer { host.close() }
                try await host.settle()
                let coordinator = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host.view, NativeChatTimelineContainer.self).first?.coordinator)
                let index = try XCTUnwrap(coordinator.rows.firstIndex { if case .legacyRequest = $0.payload { true } else { false } })
                let cell = try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? ChatNativeShellCell)
                XCTAssertEqual(cell.request.parityTexts.first { $0.id.hasSuffix("/status") }?.text.string, "awaiting vendor response")
            }
        } catch { await f.close(); throw error }
        await f.close()
    }

    func testNativeUnknownProviderFailureRetainsFullTextAndTwoVisibleLines() async throws {
        let f = try await ChatNativeActionFixture(width: 420)
        do {
            try source("unknown-error-two-lines", message: f.messages[0], fixture: f.base)
            try await f.settle()
            let reason = String(repeating: "A long upstream explanation remains in the existing two-line state label. ", count: 3)
            let word = "unexpected provider state: " + reason
            let stored: (String, String?) = try await f.base.store.queue.read { db in
                let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT state, failure_reason FROM requests WHERE request_id = 'w07-source-0'"))
                return (row["state"], row["failure_reason"])
            }
            XCTAssertEqual(stored.0, "unexpected_provider_state")
            XCTAssertEqual(stored.1, reason)
            XCTAssertTrue(f.model.sourceStatuses.contains { $0.id == "w07-source-0" && $0.state == "unexpected_provider_state" && $0.error == reason && $0.word == word })
            let cell = try f.row(f.messages[0].id)
            let observed = try P.native(coordinator: f.coordinator, cell: cell, in: f.view)
                .elements.first { $0.id == "w07/source/w07-source-0/status" }
            XCTAssertEqual(observed?.text, word)
            XCTAssertEqual(observed?.lineBreaks?.count, 2)
        } catch { await f.close(); throw error }
        await f.close()
    }

    func testW07ReactorContentAgainstActualLegacyThreeCheckGate() async throws {
        let run = try W07CaptureRun()
        defer { run.close() }
        let states = run.select(["names-and-former-member", "show-more", "second-page", "empty", "error-retry", "loading", "inaccessible"], family: "reactors")
        let fixture = try await ChatChannelExecutionTests.Fixture(root: run.scratch)
        let previousTeam = TeamService.sharedForTesting
        let previousOrg = ChatOrgCurrent.sharedForTesting
        TeamService.sharedForTesting = fixture.teamService
        ChatOrgCurrent.sharedForTesting = fixture.service.orgCurrent
        defer { fixture.sender?.hold(); TeamService.sharedForTesting = previousTeam; ChatOrgCurrent.sharedForTesting = previousOrg; ChatOrgCurrent.shared.refresh() }
        let reference = try ChatTimelineReferenceCapture(output: run.output.appendingPathComponent("legacy"),
            me: fixture.key.accountId, evidenceRoot: run.output)
        let socket = ChatSocket(server: fixture.key.server, token: "test-only", makeTransport: { FakeSocketTransport() })
        let sync = ChatSync(key: fixture.key, store: fixture.store,
            api: ChatAPI(server: fixture.key.server, protocolClasses: [W07CaptureReactorsProtocol.self]),
            socket: socket, outbox: nil, token: "test-only")
        let previousSync = fixture.service.orgSessions[fixture.key]?.sync
        fixture.service.orgSessions[fixture.key]?.sync = sync
        sync.b1.configure(["chat.reactions"]); sync.b1.resume()
        defer {
            sync.stop(); socket.stop(); W07CaptureReactorsProtocol.release()
            fixture.service.orgSessions[fixture.key]?.sync = previousSync
            fixture.service.orgSessions[fixture.key]?.snapshotOwed = false
        }
        do {
            for dark in [false, true] {
                run.theme(dark: dark)
                for width in ChatNativeParityCaptureWidths.standard {
                    for state in states {
                        try reset(fixture)
                        let message = try ChatTimelineReferenceFixture.message("w07-reactors", me: fixture.key.accountId)
                        try seed(message, fixture: fixture); try metadata("one", message: message, fixture: fixture)
                        let accounts = state == "empty" ? [] : [fixture.key.accountId, CallJSON.boris, "w07-former-member"]
                        let next: String? = state == "show-more" || state == "second-page" ? "w07-next" : nil
                        let response = try JSONEncoder().encode(ChatB1.ReactorsPage(asOfSeq: 1000, accountIds: accounts, next: next))
                        let more = try JSONEncoder().encode(ChatB1.ReactorsPage(asOfSeq: 1000, accountIds: ["w07-second-former"], next: nil))
                        W07CaptureReactorsProtocol.configure(path: "/v1/orgs/\(fixture.key.orgId)/channels/\(message.channelId)/messages/\(message.id)/reactions",
                            held: state == "loading", failure: state == "error-retry", first: response, more: more)
                        let b1 = ChatB1Channel(key: fixture.key, channel: message.channelId, store: fixture.store, service: fixture.service)
                        let model = ChatTimelineReferenceModel(fixture, messages: [message]); model.b1 = b1
                        let actions = ChatTimelineActions(model: model, root: nil, conversation: ChatTimelineAdapter.conversation(model, root: nil))
                        actions.update(archived: false, mentionable: [])
                        let nativeContent = try XCTUnwrap(actions.reactorsView(messageID: message.id, emoji: "👍", members: reference.members))
                        defer { actions.invalidate(); W07CaptureReactorsProtocol.release() }
                        fixture.service.orgSessions[fixture.key]?.snapshotOwed = state == "inaccessible"
                        try ChatTimelineReferenceCapture.prepareOrganization(fixture.service)
                        var required = ["w07/reactors/title"]
                        switch state {
                        case "inaccessible": required.append("w07/reactors/unavailable")
                        case "loading": required.append("w07/reactors/spinner")
                        case "empty": required.append("w07/reactors/empty")
                        case "error-retry": required += ["w07/reactors/error", "w07/reactors/retry"]
                        default:
                            required += accounts.map { "w07/reactors/account/" + $0 }
                            if state == "show-more" { required.append("w07/reactors/more") }
                            if state == "second-page" { required.append("w07/reactors/account/w07-second-former") }
                        }
                        try await externalPair(id: "reactors-\(state)-\(Int(width))-\(dark ? "dark" : "light")", inventory: ["R28"],
                            legacy: AnyView(ChatReactorsView(b1: b1, message: message.id, emoji: "👍", members: reference.members)),
                            native: nativeContent, width: width, dark: dark, run: run, required: required,
                            fixture: ["state": state, "accounts": accounts, "next": next ?? NSNull(), "secondPage": ["w07-second-former"],
                                "accessible": b1.state.accessible, "nativeContent": "ChatTimelineActions.reactorsView → ChatNativeReactorsContent",
                                "placementCertified": false]) { legacy, native in
                                for _ in 0..<4 { try await legacy.settle(); try await native.settle() }
                                if state == "second-page" {
                                    for host in [legacy, native] {
                                        APQuietSelectWindow(host.window); try host.press("Show more")
                                        try await host.settle(); try await host.settle()
                                    }
                                }
                                if state == "loading" { XCTAssertGreaterThanOrEqual(W07CaptureReactorsProtocol.heldCount, 2) }
                            }
                    }
                }
            }
            try run.verifyCount(states.count * 4)
        } catch { await fixture.service.disconnect(); throw error }
        await fixture.service.disconnect()
    }

    /// External popup bodies remain SwiftUI by specification. Each side below
    /// is the actual content returned by its production action path; popup
    /// anchoring, gating and reuse are certified by ChatNativeReactorsTests.
    private func externalPair(id: String, inventory: [String], legacy legacyBody: AnyView, native nativeBody: AnyView,
                              width: CGFloat, dark: Bool, run: W07CaptureRun, required: [String], fixture: Any,
                              prepare: (ChatQuietHost, ChatQuietHost) async throws -> Void) async throws {
        func plain(_ body: AnyView) -> AnyView {
            AnyView(VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 24)
                body.chatParity("externalContent", "row")
                Spacer(minLength: 0)
            }.frame(width: width, height: 600, alignment: .topLeading))
        }
        func styled(_ content: AnyView) -> AnyView {
            AnyView(content.background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.timeZone, TimeZone(identifier: "Europe/Amsterdam")!)
                .environment(\.colorScheme, dark ? .dark : .light))
        }
        let left = plain(legacyBody), right = plain(nativeBody)
        let legacyMeasured = ChatTimelineParityLayout.legacy(content: left)
        let nativeMeasured = ChatTimelineParityLayout.legacy(content: right)
        let legacyHosting = NSHostingView<AnyView>(rootView: styled(legacyMeasured.content))
        let nativeHosting = NSHostingView<AnyView>(rootView: styled(nativeMeasured.content))
        let legacy = ChatQuietHost(view: legacyHosting, dark: dark, width: width, height: 600)
        let native = ChatQuietHost(view: nativeHosting, dark: dark, width: width, height: 600)
        defer { legacy.close(); native.close() }
        try await prepare(legacy, native)
        for host in [legacy, native] {
            APQuietSelectWindow(host.window); XCTAssertTrue(host.window.makeFirstResponder(nil)); try await host.settle()
        }
        APQuietSelectWindow(legacy.window)
        let current = try P.legacy(legacyMeasured.collector, in: legacy.view), expected = try P.bitmap(legacy.view)
        APQuietSelectWindow(native.window)
        let candidate = try P.legacy(nativeMeasured.collector, in: native.view), actual = try P.bitmap(native.view)
        let branches = required.allSatisfy { id in current.elements.contains { $0.id == id } && candidate.elements.contains { $0.id == id } }
        XCTAssertTrue(branches, "Both actual external content branches must be observed: " + id)
        var observations: [String: Any] = ["requiredObservedIDs": required, "requiredBranchesVerified": branches,
            "legacyAX": legacy.strings, "nativeAX": native.strings, "diagnosticStateFilter": run.filterDescription,
            "contentPixels": true, "placementCertified": false]
        legacyHosting.rootView = styled(AnyView(left.chatParity("viewport", "viewport", colors: ["background": ChatAppearance.surface])
            .environment(\.chatParityEnabled, false)))
        APQuietSelectWindow(legacy.window); try await legacy.settle()
        XCTAssertTrue(ChatTimelineReferenceCapture.descendants(legacy.view, ChatTimelineParityProbeView.self).isEmpty)
        let clean = try P.bitmap(legacy.view)
        let neutrality = ChatTimelineParity.bitmap(try .init(expected), try .init(clean))
        observations["instrumentationNeutral"] = neutrality.passes
        observations["instrumentationPixels"] = try P.json(neutrality)
        observations["instrumentationExactDifferentPixels"] = ChatTimelineParity.exactDifference(try .init(expected), try .init(clean))
        XCTAssertTrue(neutrality.passes, "Observation changed actual external content: " + id)
        try P.record(id: id, testName: name, inventory: inventory, current: current, candidate: candidate, expected: expected, actual: actual,
            fixture: fixture, observations: observations, output: run.output)
    }

    func testW07RetainedRequestSessionAgainstActualLegacyThreeCheckGate() async throws {
        let run = try W07CaptureRun()
        defer { run.close() }
        let states = run.select(["available", "stale-error", "unavailable"], family: "retained")
        let f = try await ChatNativeRetainedRequestFixture(directory: run.scratch.appendingPathComponent("retained"))
        let previousTeam = TeamService.sharedForTesting, previousOpen = TeamUI.openTab
        let previousOrg = ChatOrgCurrent.sharedForTesting
        TeamService.sharedForTesting = f.base.teamService
        ChatOrgCurrent.sharedForTesting = f.base.service.orgCurrent
        var opened: [[String]] = []
        TeamUI.openTab = { folder, command, title in opened.append([folder, command, title]) }
        defer { TeamService.sharedForTesting = previousTeam; TeamUI.openTab = previousOpen; ChatOrgCurrent.sharedForTesting = previousOrg; ChatOrgCurrent.shared.refresh() }
        let reference = try ChatTimelineReferenceCapture(output: run.output.appendingPathComponent("legacy"),
            me: f.base.key.accountId, evidenceRoot: run.output)
        let transcript = try Data(contentsOf: f.transcriptURL)
        do {
            for dark in [false, true] {
                run.theme(dark: dark)
                for width in ChatNativeParityCaptureWidths.standard {
                    for state in states {
                        try f.restoreTranscript(transcript); f.owner.revision += 1
                        try await f.settle(); try ChatTimelineReferenceCapture.prepareOrganization(f.base.service)
                        let card = try XCTUnwrap(f.model.threadRequests.first { $0.id == f.requestID })
                        let plain = AnyView(VStack(spacing: 0) {
                            Color.clear.frame(height: 24)
                            ChatRequestCardRow(card: card, members: reference.members, ownerModel: f.owner)
                                .padding(.horizontal, 18).chatParity("legacyRequest:" + card.id, "row")
                            Spacer(minLength: 0)
                        }.frame(width: width, height: 600, alignment: .topLeading))
                        let measured = ChatTimelineParityLayout.legacy(content: plain)
                        func styled(_ content: AnyView) -> AnyView {
                            AnyView(content.background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
                                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                                .environment(\.timeZone, TimeZone(identifier: "Europe/Amsterdam")!)
                                .environment(\.colorScheme, dark ? .dark : .light))
                        }
                        let legacyHosting = NSHostingView<AnyView>(rootView: styled(measured.content))
                        let legacy = ChatQuietHost(view: legacyHosting, dark: dark, width: width, height: 600)
                        let adapter = ChatTimelineAdapter(), coordinator = NativeChatTimelineCoordinator()
                        let view = NativeChatTimelineContainer(coordinator: coordinator)
                        let native = ChatQuietHost(view: view, dark: dark, width: width, height: 600)
                        defer { coordinator.dispose(); adapter.invalidate(); legacy.close(); native.close() }
                        func update() throws {
                            APQuietSelectWindow(native.window)
                            let full = adapter.snapshot(model: f.model, root: f.rootID, members: reference.members, mentionable: [],
                                me: f.base.key.accountId, archived: false, ownerModel: f.owner,
                                style: ChatTimelineAdapter.style(scale: native.window.backingScaleFactor, locale: .current,
                                    calendar: .current, increasedContrast: false, alwaysShowTime: false))
                            let row = try XCTUnwrap(full.rows.first { if case .legacyRequest(let request) = $0.payload { return request.id == f.requestID }; return false })
                            let inset = S.Row(id: .init(conversation: full.conversation, kind: .topInset), contentRevision: 1,
                                layoutRevision: 1, payload: .inset(24), visual: nil)
                            coordinator.actions = adapter.actions
                            view.update(S(conversation: full.conversation, presentationEpoch: full.presentationEpoch, generation: full.generation,
                                rows: [inset, row], messageIDs: [], messageAliases: full.messageAliases, members: full.members,
                                mentionable: full.mentionable, me: full.me, style: full.style, state: full.state, commands: []))
                        }
                        for _ in 0..<3 {
                            APQuietSelectWindow(legacy.window); try ChatTimelineReferenceCapture.prepareOrganization(f.base.service)
                            try await legacy.settle(); try update(); try await native.settle()
                        }
                        let cell = try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: 1, makeIfNecessary: false) as? ChatNativeShellCell)
                        let before = opened.count
                        if state == "available" {
                            APQuietSelectWindow(legacy.window); try legacy.press("Open Session")
                            APQuietSelectWindow(native.window); try XCTUnwrap(cell.request.parityControls["w07/request/\(f.requestID)/Open Session"]).performClick(nil)
                            XCTAssertEqual(opened.count, before + 2)
                            XCTAssertEqual(Array(opened.suffix(2)), Array(repeating: [f.base.agent.folder,
                                "claude --resume \(f.run.conversationId) --fork-session", "Channel · your copy"], count: 2))
                        } else {
                            for host in [legacy, native] {
                                let bytes = try f.takeTranscript()
                                APQuietSelectWindow(host.window)
                                if host === legacy { try legacy.press("Open Session") }
                                else { try XCTUnwrap(cell.request.parityControls["w07/request/\(f.requestID)/Open Session"]).performClick(nil) }
                                try f.restoreTranscript(bytes)
                                f.owner.revision += 1
                            }
                            XCTAssertEqual(opened.count, before)
                            if state == "unavailable" { _ = try f.takeTranscript(); f.owner.revision += 1 }
                        }
                        for _ in 0..<2 { try await legacy.settle(); try update(); try await native.settle() }
                        for host in [legacy, native] {
                            APQuietSelectWindow(host.window); try ChatTimelineReferenceCapture.prepareOrganization(f.base.service)
                            XCTAssertTrue(host.window.makeFirstResponder(nil)); try await host.settle()
                        }
                        APQuietSelectWindow(legacy.window)
                        try ChatTimelineReferenceCapture.prepareOrganization(f.base.service); try await legacy.settle()
                        let current = try P.legacy(measured.collector, in: legacy.view), expected = try P.bitmap(legacy.view)
                        APQuietSelectWindow(native.window)
                        let candidate = try nativeCapture(coordinator: coordinator, cell: cell, in: view)
                        let actual = try P.bitmap(view)
                        var required = ["w07/request/\(f.requestID)/card", "w07/request/\(f.requestID)/Open Request…"]
                        if state != "unavailable" { required.append("w07/request/\(f.requestID)/Open Session") }
                        if state == "stale-error" { required.append("w07/request/\(f.requestID)/problem") }
                        let branches = required.allSatisfy { id in current.elements.contains { $0.id == id } && candidate.elements.contains { $0.id == id } }
                        XCTAssertTrue(branches)
                        if state == "unavailable" {
                            for value in [current, candidate] {
                                XCTAssertFalse(value.elements.contains { $0.id.hasSuffix("/Open Session") || $0.id.hasSuffix("/problem") })
                            }
                        }
                        var observations: [String: Any] = ["requiredObservedIDs": required, "requiredBranchesVerified": branches,
                            "legacyAX": legacy.strings, "nativeAX": native.strings, "sessionOpenDispatches": opened.count - before,
                            "diagnosticStateFilter": run.filterDescription, "terminalOpened": false]
                        legacyHosting.rootView = styled(AnyView(plain.chatParity("viewport", "viewport", colors: ["background": ChatAppearance.surface])
                            .environment(\.chatParityEnabled, false)))
                        APQuietSelectWindow(legacy.window); try await legacy.settle()
                        XCTAssertTrue(ChatTimelineReferenceCapture.descendants(legacy.view, ChatTimelineParityProbeView.self).isEmpty)
                        let clean = try P.bitmap(legacy.view)
                        let neutrality = ChatTimelineParity.bitmap(try .init(expected), try .init(clean))
                        observations["instrumentationNeutral"] = neutrality.passes
                        observations["instrumentationPixels"] = try P.json(neutrality)
                        observations["instrumentationExactDifferentPixels"] = ChatTimelineParity.exactDifference(try .init(expected), try .init(clean))
                        XCTAssertTrue(neutrality.passes)
                        try P.record(id: "retained-\(state)-\(Int(width))-\(dark ? "dark" : "light")", testName: name, inventory: ["R47", "R48"],
                            current: current, candidate: candidate, expected: expected, actual: actual,
                            fixture: ["state": state, "request": requestDescription(card), "transcriptAvailable": f.owner.canOpenSession(f.requestID),
                                "realF6Run": f.run.runId, "error": adapter.actions?.requestProblem(requestID: f.requestID) ?? NSNull()],
                            observations: observations, output: run.output)
                    }
                }
            }
            try run.verifyCount(states.count * 4)
        } catch { await f.close(); throw error }
        await f.close()
    }

    func testW07SavedAskReplacementSurvivesTimelineScrollAndReload() async throws {
        XCTAssertTrue(APQuietIsEnabled())
        ChatScrollAppKitSettings.install(); AgentPadFonts.registerOnce(); _ = NSApplication.shared
        let settings = AgentPadSettingsModel.shared
        let previousTheme = (settings.appearanceMode, settings.lightTerminalThemeSelection,
            settings.darkTerminalThemeSelection, settings.pairedThemeSchemaEnabled)
        settings.prepareFirstLaunchAppearance()
        settings.lightTerminalThemeSelection = AgentPadSettingsModel.defaultLightThemeSelection
        settings.darkTerminalThemeSelection = AgentPadSettingsModel.defaultDarkThemeSelection
        defer {
            if !previousTheme.3 { settings.load() }
            settings.appearanceMode = previousTheme.0
            settings.lightTerminalThemeSelection = previousTheme.1
            settings.darkTerminalThemeSelection = previousTheme.2
        }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhanced = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previousEnhanced, forAttribute: enhanced) }
        let f = try await ChatNativeRetainedRequestFixture()
        let previousTeam = TeamService.sharedForTesting, previousOrg = ChatOrgCurrent.sharedForTesting
        TeamService.sharedForTesting = f.base.teamService
        ChatOrgCurrent.sharedForTesting = f.base.service.orgCurrent
        defer { TeamService.sharedForTesting = previousTeam; ChatOrgCurrent.sharedForTesting = previousOrg; ChatOrgCurrent.shared.refresh() }
        let members = [ChatOrgView.Member(accountId: f.base.key.accountId, handle: "anna", name: "Anna", role: "owner")]
        let agents = [ChatChannelAgent(channelId: f.model.channel, agentId: CallJSON.agent, name: "billing",
            ownerAccountId: f.base.key.accountId, ownerHandle: "anna", description: "Billing fixture", access: "read",
            enabled: true, available: true, executorDeviceName: "Fixture Mac")]
        do {
            for index in 1...40 {
                try seed(ChatTimelineReferenceFixture.message("w07-replacement-\(index)", me: f.base.key.accountId,
                    text: "Fixture message \(index) gives the timeline room to scroll.", seq: index + 1), fixture: f.base)
            }
            for dark in [false, true] {
                settings.appearanceMode = dark ? .dark : .light
                for width: CGFloat in [760, 420, 320] {
                    do {
                        let renderer = "native"
                        try f.base.write("DELETE FROM composition_drafts WHERE id = ?", ["channel-ask:" + f.model.channel])
                        let model = ChatChannelModel(key: f.base.key, channel: f.model.channel)
                        let confirmation = ConfirmationCoordinator()
                        model.service = f.base.service; model.tabID = UUID(); model.confirmation = confirmation
                        model.follow(f.base.store)
                        let offer = ChatChannelAsk.Offer(messageId: f.rootID, agentId: CallJSON.agent, address: "billing@anna",
                            text: "The original fixture question.", root: f.rootID)
                        model.beginAsk(offer)
                        let form = try XCTUnwrap(model.channelAsk)
                        form.fields.text = "Keep this edited question and its selected context."
                        let saved = form.fields
                        func content(probes: Bool) -> AnyView {
                            AnyView(VStack(spacing: 0) {
                                ChatChannelOwnerPanel(model: f.owner)
                                ChatTimelineView(model: model, root: nil, members: members,
                                    mentionable: members.map { ($0.accountId, $0.handle) }, me: f.base.key.accountId,
                                    archived: false, ownerModel: f.owner)
                                ChatAskStrip(model: model, agents: agents)
                            }.frame(width: width, height: 1000)
                                .chatParity("w09/caller/text-inventory", "container")
                                .background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
                                .environment(\.locale, Locale.current).environment(\.timeZone, TimeZone.current)
                                .environment(\.colorScheme, dark ? .dark : .light)
                                .environment(\.chatParityEnabled, probes))
                        }
                        let hosting = NSHostingView(rootView: content(probes: true))
                        let host = ChatQuietHost(view: hosting, dark: dark, width: width, height: 1000)
                        defer { hosting.rootView = AnyView(EmptyView()); host.close() }
                        for _ in 0..<4 {
                            try ChatTimelineReferenceCapture.prepareOrganization(f.base.service); try await host.settle()
                        }
                        try host.press("Keep draft"); try await host.settle()
                        XCTAssertFalse(form.expanded)
                        XCTAssertTrue(host.strings.contains("Edit saved channel question"))
                        let second = ChatChannelAsk.Offer(messageId: "w07-replacement-1", agentId: CallJSON.agent,
                            address: "billing@anna", text: "A different fixture question.", root: "w07-replacement-1")
                        model.beginAsk(second)
                        try await host.settle()
                        let context = try XCTUnwrap(confirmation.context)
                        XCTAssertEqual(context.targetID, "channel-ask:" + model.channel)
                        XCTAssertEqual(context.revision, saved.requestID)
                        let container = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host.view, NativeChatTimelineContainer.self).first)
                        let scroll = container.coordinator.scrollView
                        let document = try XCTUnwrap(scroll.documentView)
                        let originalEditor = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host.view, NSTextView.self)
                            .first { $0.isEditable && $0.string == saved.text })
                        let originalSelection = originalEditor.selectedRange()
                        ChatScrollAppKitSettings.apply(to: scroll)
                        func sourceVisible() -> Bool {
                            guard let index = container.coordinator.messageIndex(f.rootID) else { return false }
                            return container.coordinator.tableView.rect(ofRow: index).intersects(scroll.contentView.bounds)
                        }
                        func preserved(_ stage: String, probes: Bool = true) throws {
                            let label = renderer + ": " + stage
                            XCTAssertTrue(model.channelAsk === form, label)
                            XCTAssertEqual(form.fields, saved, label)
                            XCTAssertEqual(try ChatCompositionDrafts.read(ChannelAskDraft.self,
                                id: "channel-ask:" + model.channel, store: f.base.store), saved, label)
                            XCTAssertTrue(form.expanded, label)
                            XCTAssertTrue(form.replacement === confirmation, label)
                            XCTAssertEqual(confirmation.context, context, label)
                            XCTAssertEqual(confirmation.phase, .awaiting, label)
                            XCTAssertTrue(confirmation.isVisible, label)
                            XCTAssertTrue(host.strings.contains("Replace saved channel question?"), label)
                            XCTAssertTrue(try host.enabled("Replace draft"), label)
                            let editor = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host.view, NSTextView.self)
                                .first { $0.isEditable && $0.string == saved.text }, label)
                            XCTAssertFalse(editor.isHiddenOrHasHiddenAncestor, label)
                            XCTAssertFalse(editor.isDescendant(of: document), label)
                            XCTAssertTrue(editor === originalEditor, label)
                            XCTAssertEqual(editor.selectedRange(), originalSelection, label)
                            guard model.channelAsk === form, form.fields == saved,
                                  try ChatCompositionDrafts.read(ChannelAskDraft.self,
                                    id: "channel-ask:" + model.channel, store: f.base.store) == saved,
                                  form.expanded, form.replacement === confirmation, confirmation.context == context,
                                  confirmation.phase == .awaiting, confirmation.isVisible,
                                  host.strings.contains("Replace saved channel question?"), try host.enabled("Replace draft"),
                                  editor === originalEditor, editor.selectedRange() == originalSelection,
                                  !editor.isHiddenOrHasHiddenAncestor, !editor.isDescendant(of: document) else {
                                throw ChatTimelineParityLayout.failure("Saved-question live ownership/input changed: " + label)
                            }
                            if probes {
                                let prompt = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host.view, ChatTimelineParityProbeView.self)
                                    .first { $0.semanticID == "w05/confirmation/title" }, label)
                                XCTAssertFalse(prompt.isDescendant(of: document), label)
                                XCTAssertFalse(prompt.visibleRect.isEmpty, label)
                            }
                        }
                        var scrollSequence = 0
                        func scrollToEdge(top: Bool) async throws {
                            scrollSequence += 1
                            var turns: [[String: Any]] = []
                            // Release follow-bottom before changing the clip, as a user scroll does.
                            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
                            // Reapply the explicitly requested edge over the existing two
                            // settling turns, then require the realized clip to reach it.
                            for turn in 0..<2 {
                                let documentBefore = document.bounds
                                let clipBefore = scroll.contentView.bounds
                                let high = max(documentBefore.minY, documentBefore.maxY - clipBefore.height)
                                let y = top == document.isFlipped ? documentBefore.minY : high
                                scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
                                scroll.reflectScrolledClipView(scroll.contentView)
                                let clipImmediatelyAfter = scroll.contentView.bounds
                                try await host.settle()
                                turns.append([
                                    "turn": turn + 1, "requestedY": y,
                                    "documentBoundsBefore": NSStringFromRect(documentBefore),
                                    "clipBoundsBefore": NSStringFromRect(clipBefore),
                                    "clipBoundsImmediatelyAfter": NSStringFromRect(clipImmediatelyAfter),
                                    "documentBoundsAfterSettling": NSStringFromRect(document.bounds),
                                    "clipBoundsAfterSettling": NSStringFromRect(scroll.contentView.bounds)
                                ])
                            }
                            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
                            let high = max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height)
                            let expected = top == document.isFlipped ? document.bounds.minY : high
                            guard scroll.contentView.bounds.minY == expected else {
                                throw ChatTimelineParityLayout.failure("Saved-question live scroll did not reach its requested edge: " + renderer)
                            }
                        }
                        try await scrollToEdge(top: true)
                        let topOrigin = scroll.contentView.bounds.minY
                        XCTAssertTrue(sourceVisible(), renderer + ": source starts onscreen")
                        try preserved("before scroll")
                        try await scrollToEdge(top: false)
                        XCTAssertGreaterThan(abs(scroll.contentView.bounds.minY - topOrigin), scroll.contentView.bounds.height)
                        XCTAssertFalse(sourceVisible(), renderer + ": source must leave the viewport")
                        XCTAssertNil(container.coordinator.tableView.view(atColumn: 0,
                            row: try XCTUnwrap(container.coordinator.messageIndex(f.rootID)), makeIfNecessary: false), "Native source cell must be recycled")
                        try preserved("source offscreen")
                        try await scrollToEdge(top: true)
                        XCTAssertTrue(sourceVisible(), renderer + ": source returns onscreen")
                        try preserved("source returned")
                        let revision = try XCTUnwrap(model.message(f.rootID)).revision
                        container.coordinator.tableView.reloadData()
                        // Both mounted timelines also reload through their real store observer.
                        try f.base.write("UPDATE messages SET revision = revision + 1 WHERE message_id = ?", [f.rootID])
                        for _ in 0..<3 { try await host.settle() }
                        XCTAssertEqual(model.message(f.rootID)?.revision, revision + 1, renderer + ": store reload reached the mounted model")
                        XCTAssertTrue(sourceVisible(), renderer + ": source survives reload")
                        try preserved("after reload")
                    }
                }
            }
        } catch { await f.close(); throw error }
        await f.close()
    }

    private func nativeCapture(coordinator: NativeChatTimelineCoordinator, cell: ChatNativeShellCell,
                               in view: NSView) throws -> ChatTimelineParityMetadata {
        var candidate = try P.native(coordinator: coordinator, cell: cell, in: view)
        if ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_W06_CAPTURE"] == "1" {
            let media = try ChatNativeMediaParity.native(coordinator: coordinator, cell: cell, in: view)
            let extra = media.elements.filter { element in
                element.id.hasPrefix("w06/") && !candidate.elements.contains { $0.id == element.id }
            }
            candidate.elements += extra
            candidate.captureGaps += media.captureGaps.filter { gap in extra.contains { gap.hasPrefix($0.id + ":") } }
            candidate.elements.sort { $0.id < $1.id }
        }
        return candidate
    }

    private func reset(_ f: ChatChannelExecutionTests.Fixture) throws {
        f.service.serverCapabilities[f.key.server] = []
        f.service.isServerKnown = { _, _ in true }
        f.service.orgSessions[f.key]?.snapshotOwed = false
        f.service.clearChannelActivity()
        try f.journal.queue.write { try $0.execute(sql: "DELETE FROM automatic_request_blocks") }
        try f.store.queue.write { db in
            for table in ["b1_intents", "b1_metadata", "b1_pins", "channel_call_intents", "channel_sends", "requests", "messages", "agents_catalog", "agent_channels"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            try db.execute(sql: "DELETE FROM outbox WHERE command_id LIKE 'w07-%'")
            try db.execute(sql: "UPDATE channels SET archived = 0")
            try db.execute(sql: "UPDATE meta SET agents_served = 1")
        }
    }
    private func seed(_ message: ChatMessage, fixture f: ChatChannelExecutionTests.Fixture) throws {
        try f.write("""
            INSERT INTO messages (message_id, channel_id, author_account_id, seq, created_at, has_fixed, has_mutable, text, mentions, revision, deleted_at, edited_at)
            VALUES (?, ?, ?, ?, ?, 1, ?, ?, '[]', 3, ?, ?)
            """, [message.id, message.channelId, message.authorAccountId, message.seq, message.createdAt,
                    message.hasMutable, message.text, message.deletedAt, message.editedAt])
    }
    private func metadata(_ state: String, message: ChatMessage, fixture f: ChatChannelExecutionTests.Fixture) throws {
        let capabilities = ["chat.reactions", "chat.pins", "chat.thread_summary"]
        let mask = state.hasPrefix("capabilities-") ? Int(state.dropFirst("capabilities-".count))! : state == "loading-placeholder" ? 1 : 7
        f.service.serverCapabilities[f.key.server] = Set(capabilities.enumerated().compactMap { mask & (1 << $0.offset) == 0 ? nil : $0.element })
        var reactions: [ChatB1.Reaction] = []
        if ["one", "mine", "pending-existing", "error-existing", "offline", "access-lost"].contains(state) {
            reactions = [.init(emoji: "👍", count: 3, mine: state == "mine")]
        }
        if state == "twelve" || state == "twenty" {
            let values = ChatTimelineReferenceFixture.emoji + (state == "twenty" ? ["✨", "💯", "😍", "🤯", "😢", "😡", "👏", "🙌"] : [])
            reactions = values.map { .init(emoji: $0, count: 3, mine: $0 == "👍") }
        }
        let metadata = ChatB1.Metadata(messageId: message.id, deleted: false, reactions: reactions,
            pin: state == "pinned" ? .init(pinnedBy: f.key.accountId, pinnedAt: ChatTimelineReferenceFixture.date) : nil, threadSummary: nil)
        try f.store.queue.write { db in
            try ChatB1.watch(db, channel: message.channelId, ids: [message.id])
            if !state.hasPrefix("capabilities-") && state != "loading-error" && state != "loading-placeholder" {
                try db.execute(sql: "UPDATE b1_metadata SET data = ?, dirty = 0, as_of_seq = 3 WHERE message_id = ?",
                    arguments: [try JSONEncoder().encode(metadata), message.id])
            }
            if state == "loading-error" {
                try db.execute(sql: "UPDATE b1_metadata SET error = 'Message details could not be loaded.' WHERE message_id = ?", arguments: [message.id])
            }
            if state.contains("pending") || state.hasPrefix("error-") || state == "pin-error" {
                let choice = state.hasPrefix("pin-") ? "pin" : state.hasSuffix("-new") ? "🎉" : "👍"
                var command = ChatCommandRecord(commandId: "w07-intent", sessionId: "s-anna", type: choice == "pin" ? "message.pin.set" : "message.reaction.set",
                    bodyBytes: Data(), orderKey: "w07-intent", createdAt: Date(timeIntervalSince1970: 1), state: .pending)
                if state.contains("error") { command.state = .dropped; command.error = "Change not confirmed. Try again." }
                try command.insert(db)
                try db.execute(sql: "INSERT INTO b1_intents (command_id, channel_id, message_id, choice, present) VALUES (?, ?, ?, ?, 1)",
                    arguments: [command.commandId, message.channelId, message.id, choice])
            }
        }
        if state == "access-lost" { f.service.orgSessions[f.key]?.snapshotOwed = true }
    }
    private func source(_ state: String, message: ChatMessage, fixture f: ChatChannelExecutionTests.Fixture) throws {
        f.service.serverCapabilities[f.key.server] = ["chat.channel_ux1", "chat.session_tools"]
        f.service.isServerKnown = { _, _ in state != "offline" }
        guard state != "none" else { return }
        if state == "local-pending" || state == "local-error" {
            var command = ChatCommandRecord(commandId: "w07-local-call", sessionId: "s-anna", type: "request.create",
                bodyBytes: Data(), orderKey: "w07-local-call", createdAt: Date(timeIntervalSince1970: 1), state: .pending)
            if state == "local-error" { command.state = .failed; command.error = "The request could not be sent." }
            try f.store.queue.write { db in
                try command.insert(db)
                try db.execute(sql: "INSERT INTO channel_sends (draft_version, channel_id, message_id, command_id) VALUES (?, ?, ?, ?)",
                    arguments: ["w07-draft", message.channelId, message.id, command.commandId])
                try db.execute(sql: "INSERT INTO channel_call_intents (request_id, message_id, agent_id, command_id) VALUES (?, ?, ?, ?)",
                    arguments: ["w07-source-0", message.id, CallJSON.agent, command.commandId])
            }
            return
        }
        let count = ["four", "expanded"].contains(state) ? 4 : state == "three" ? 3 : 1
        let publications = ["published", "awaiting_publish", "withheld", "publish_failed"]
        for index in 0..<count {
            let requestState = publications.contains(state) || ["answer", "automatic-publication-cancelled"].contains(state) ? "finished"
                : ["offline", "activity", "action-problem", "three", "four", "expanded", "deleted"].contains(state) ? "running" : state
            var body = CallJSON.request("w07-source-\(index)", state: requestState, version: 1)
            body["kind"] = "channel"; body["channel_id"] = message.channelId
            body["source_message_id"] = message.id; body["thread_root_id"] = message.id
            if publications.contains(state) { body["publication"] = state }
            if state == "publish_failed" { body["publish_reason"] = "agent_disabled" }
            if state == "failed" { body["failure_reason"] = "The agent could not finish." }
            if state == "unknown-error-two-lines" {
                body["state"] = "unexpected_provider_state"
                body["failure_reason"] = String(repeating: "A long upstream explanation remains in the existing two-line state label. ", count: 3)
            }
            if state == "answer" { body["publication"] = "published"; body["run_id"] = "w07-answer-run" }
            if state == "automatic-publication-cancelled" { body["publication"] = "awaiting_publish" }
            if state == "action-problem" { body["owner_account_id"] = f.key.accountId }
            let wire = CallJSON.wire(body)
            try f.store.queue.write { try ChatCallStore.apply($0, wire, onThisDevice: false) }
        }
        if state == "activity" {
            f.service.channelActivity["w07-source-0"] = .init(key: f.key, request: "w07-source-0", text: "Reading files",
                expires: Date().addingTimeInterval(3600))
        }
        if state == "answer" {
            try f.write("""
                INSERT INTO messages (message_id, channel_id, author_account_id, seq, created_at, has_fixed, has_mutable, text, mentions, revision, run_id, thread_root_id)
                VALUES ('w07-answer', ?, ?, 4, ?, 1, 1, 'The agent answer.', '[]', 1, 'w07-answer-run', ?)
                """, [message.channelId, f.key.accountId, ChatTimelineReferenceFixture.date, message.id])
        }
        if state == "automatic-publication-cancelled" { try f.journal.blockAutomaticRequest(f.key, request: "w07-source-0") }
    }
    private func request(_ state: String, fixture f: ChatChannelExecutionTests.Fixture) -> ChatChannelRequests.Card {
        let reasons = ["agent_removed", "agent_disabled", "owner_left_team", "channel_archived", "initiator_removed", "initiator_left_team", "unknown_reason", "missing_reason"]
        let finished = reasons.contains(state) || ["finished", "awaiting_publish", "published", "withheld"].contains(state)
        return .init(requestId: "w07-request", agentName: "Billing agent",
            initiatorAccountId: state == "former-member" ? "former-initiator" : f.key.accountId,
            ownerAccountId: state == "former-member" ? "former-owner" : CallJSON.boris,
            state: TeamRequestState(rawValue: finished ? "finished" : ["owner", "former-member"].contains(state) ? "submitted" : state),
            publication: reasons.contains(state) ? "publish_failed" : finished && state != "finished" ? state : nil,
            publishReason: state == "missing_reason" ? nil : reasons.contains(state) ? state : nil, cause: nil)
    }
    private func requestDescription(_ value: ChatChannelRequests.Card) -> [String: Any] {
        ["id": value.id, "titleAgent": value.agentName, "state": value.state.rawValue, "word": value.stateWord,
            "initiator": value.initiatorAccountId ?? NSNull(), "owner": value.ownerAccountId ?? NSNull(),
            "publication": value.publication ?? NSNull(), "reason": value.publishReason ?? NSNull(), "cause": value.cause ?? NSNull()]
    }

}

@MainActor private final class W07CaptureRun {
    let output: URL, scratch: URL
    private let stateFilter: Set<String>
    var filterDescription: [String] { stateFilter.sorted() }
    func select(_ states: [String], family: String) -> [String] {
        let selected = stateFilter.isEmpty ? states : states.filter { stateFilter.contains($0) || stateFilter.contains(family + ":" + $0) }
        if stateFilter.isEmpty { XCTAssertEqual(selected.count, states.count, "Final acceptance must include every declared state") }
        return selected
    }
    func verifyCount(_ expected: Int) throws {
        let records = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "run-selection.json" }
        XCTAssertEqual(records.count, expected, "Every selected theme/width/state must produce one complete pair")
        try JSONSerialization.data(withJSONObject: ["expectedPairs": expected, "recordedPairs": records.count,
            "diagnosticStateFilter": filterDescription, "filteredDiagnosticRun": !stateFilter.isEmpty], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("run-selection.json"))
    }
    private let scope: TeamServiceTestScope
    private let previousBadge = ChatNotifications.badgeChanged
    private let previousTheme: (AgentPadAppearanceMode, String, String, Bool)
    private let previousTime: Any?, previousEnhanced: Any?
    init() throws {
        guard ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_W07_CAPTURE"] == "1" else {
            throw XCTSkip("Set AGENTPAD_CHAT_NATIVE_W07_CAPTURE=1 to record metadata pairs")
        }
        XCTAssertTrue(APQuietIsEnabled())
        stateFilter = Set((ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_W07_STATES"] ?? "")
            .split(separator: ",").map(String.init))
        ChatScrollAppKitSettings.install(); AgentPadFonts.registerOnce(); _ = NSApplication.shared
        scope = TeamServiceTestScope()
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        previousEnhanced = NSApp.accessibilityAttributeValue(enhanced); NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        let root = try ChatTimelineReferencePaths.root(try XCTUnwrap(ProcessInfo.processInfo.environment["AGENTPAD_CHAT_PARITY_EVIDENCE"]))
        output = root.appendingPathComponent("w07-metadata-" + UUID().uuidString); scratch = output.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["diagnosticStateFilter": stateFilter.sorted(), "filteredDiagnosticRun": !stateFilter.isEmpty],
            options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("run-selection.json"))
        ChatStubProtocol.reset { _, _ in .failure(URLError(.unsupportedURL)) }; ChatNotifications.badgeChanged = {}
        let settings = AgentPadSettingsModel.shared
        previousTheme = (settings.appearanceMode, settings.lightTerminalThemeSelection, settings.darkTerminalThemeSelection, settings.pairedThemeSchemaEnabled)
        settings.prepareFirstLaunchAppearance()
        settings.lightTerminalThemeSelection = AgentPadSettingsModel.defaultLightThemeSelection
        settings.darkTerminalThemeSelection = AgentPadSettingsModel.defaultDarkThemeSelection
        previousTime = UserDefaults.standard.object(forKey: "chat.ux2.alwaysShowTime")
        UserDefaults.standard.set(false, forKey: "chat.ux2.alwaysShowTime")
    }
    func theme(dark: Bool) { AgentPadSettingsModel.shared.appearanceMode = dark ? .dark : .light }
    func close() {
        ChatStubProtocol.reset(); scope.close(); ChatNotifications.badgeChanged = previousBadge
        NSApp.accessibilitySetValue(previousEnhanced, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let settings = AgentPadSettingsModel.shared
        if !previousTheme.3 { settings.load() }
        settings.appearanceMode = previousTheme.0; settings.lightTerminalThemeSelection = previousTheme.1; settings.darkTerminalThemeSelection = previousTheme.2
        if let previousTime { UserDefaults.standard.set(previousTime, forKey: "chat.ux2.alwaysShowTime") }
        else { UserDefaults.standard.removeObject(forKey: "chat.ux2.alwaysShowTime") }
        try? FileManager.default.removeItem(at: scratch)
    }
}
