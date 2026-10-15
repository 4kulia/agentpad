import AppKit
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

private actor TelegramDeliveryProvider: TelegramChatProvider {
    var consumed = Set<String>()
    func consumeNotification(_ id: String) -> Bool { consumed.insert(id); return true }
    func chatSnapshots() -> AsyncStream<TelegramChatSnapshot> { AsyncStream { $0.finish() } }
    func setChatMode(_ id: TelegramChatID, mode: TelegramChatMode) {}
    func searchTelegram(_ query: String) -> AsyncStream<TelegramSearchSnapshot> { AsyncStream { $0.finish() } }
    func resolveChat(_ hit: TelegramSearchHit) -> TelegramChatRow? { nil }
    func didOpenChat(_ id: TelegramChatID) {}
    func chat(_ id: TelegramChatID) -> TelegramChatRow? { nil }
    func setChatScanPaused(_ reason: String?) {}
}

@MainActor final class TelegramNotificationDeliveryTests: XCTestCase {
    func testPendingCategoryIsNotConsumedOrSuppressedBeforeResolution() async {
        for kind: TelegramAttentionKind in [.reply, .mention] {
            let center = RecordingNotificationCenter(), adapter = TelegramNotifications(), provider = TelegramDeliveryProvider()
            let manager = NotificationManager(client: center); adapter.manager = manager
            adapter.preferences = { .init(disabled: [.mentions]) }; adapter.isFocused = { _ in false }
            var value = snapshot(); value.attention.notifications.items[0].categoryPending = true
            let id = value.attention.notifications.items[0].id
            // An unresolved category must not block a ready notification.
            var ready = value.attention.notifications.items[0]
            ready.id += "-ready"; ready.kind = .direct; ready.categoryPending = false
            value.attention.notifications.items.append(ready)
            adapter.receive(value, provider: provider); await settle(manager)
            adapter.settingsChanged(provider: provider); await settle(manager)
            let pendingConsumed = await provider.consumed
            XCTAssertEqual(pendingConsumed, [ready.id]); XCTAssertEqual(center.submitted.map(\.id), [ready.id])
            value.attention.notifications.items[0].kind = kind
            value.attention.notifications.items[0].categoryPending = false
            adapter.receive(value, provider: provider); await settle(manager)
            let consumed = await provider.consumed
            XCTAssertTrue(consumed.contains(id))
            XCTAssertEqual(center.submitted.count, kind == .reply ? 2 : 1)
            if kind == .reply { XCTAssertTrue(center.submitted.last?.sound == true) }
            adapter.receive(value, provider: provider); await settle(manager)
            XCTAssertEqual(center.submitted.count, kind == .reply ? 2 : 1)
        }
    }

    func testPendingCategoryTimeoutUsesEitherEnabledCategoryWithoutAnotherSnapshot() async throws {
        for disabled: Set<AttentionCategory> in [[], [.mentions], [.replies], [.mentions, .replies]] {
            let center = RecordingNotificationCenter(), adapter = TelegramNotifications(), provider = TelegramDeliveryProvider()
            let manager = NotificationManager(client: center); adapter.manager = manager
            adapter.preferences = { .init(disabled: disabled) }; adapter.isFocused = { _ in false }
            adapter.categoryTimeout = .milliseconds(10)
            var value = snapshot(); value.attention.notifications.items[0].categoryPending = true
            adapter.receive(value, provider: provider)
            for _ in 0..<200 {
                if !(await provider.consumed).isEmpty { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            await settle(manager)
            let consumed = await provider.consumed
            XCTAssertEqual(consumed, [value.attention.notifications.items[0].id])
            XCTAssertEqual(center.submitted.count, disabled.count == 2 ? 0 : 1)
            if disabled.count != 2 { XCTAssertTrue(center.submitted.first?.sound == true) }
            value.attention.notifications.items[0].kind = .reply
            value.attention.notifications.items[0].categoryPending = false
            adapter.receive(value, provider: provider); await settle(manager)
            XCTAssertEqual(center.submitted.count, disabled.count == 2 ? 0 : 1, "Late resolution cannot replay a timeout delivery")
        }
    }

    func testPendingCategoryIsDiscardedOnRemovalLogoutOrAccountChange() async throws {
        for reset in ["remove", "logout", "account"] {
            let center = RecordingNotificationCenter(), adapter = TelegramNotifications(), provider = TelegramDeliveryProvider()
            let manager = NotificationManager(client: center); adapter.manager = manager
            adapter.preferences = { .init(disabled: [.mentions]) }; adapter.isFocused = { _ in false }
            adapter.categoryTimeout = .milliseconds(10)
            var value = snapshot(); value.attention.notifications.items[0].categoryPending = true
            adapter.receive(value, provider: provider)
            if reset == "logout" { adapter.disconnect() }
            else {
                value.attention.notifications.items = []
                if reset == "account" { value.account = .init(environment: .test, account: 43, chat: 1) }
                adapter.receive(value, provider: provider)
            }
            try await Task.sleep(for: .milliseconds(30)); await settle(manager)
            let consumed = await provider.consumed
            XCTAssertTrue(consumed.isEmpty); XCTAssertTrue(center.submitted.isEmpty)
        }
    }

    private final class FocusWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isVisible: Bool { true }
    }

    func testFocusRequiresActiveAppAndShownTabInTheSameChat() async {
        let window = FocusWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: window.contentLayoutRect), key = UUID()
        window.contentView = view
        let chat = TelegramChatID(environment: .test, account: 42, chat: 1)
        AttentionFocus.places[key] = ([.telegram(chat.root, message: 0)], AttentionFocus.WeakView(view))
        defer { AttentionFocus.places[key] = nil; window.contentView = nil; window.close() }
        for (active, shown, target, shouldDeliver) in [
            (true, true, chat, false), (false, true, chat, true), (true, false, chat, true),
            (true, true, TelegramChatID(environment: .test, account: 42, chat: 2), true),
            (true, true, chat.withTopic(.forum(7)), false)
        ] {
            view.isHidden = !shown
            let center = RecordingNotificationCenter(), adapter = TelegramNotifications(), provider = TelegramDeliveryProvider()
            let manager = NotificationManager(client: center); adapter.manager = manager
            adapter.isFocused = { AttentionFocus.focused(.telegram($0.root, message: 0), appActive: active) }
            var value = snapshot(); value.attention.notifications.items[0].destination = target
            adapter.receive(value, provider: provider); await settle(manager)
            XCTAssertEqual(center.submitted.count, shouldDeliver ? 1 : 0)
        }
    }

    func testFocusedChatSuppressesUnviewedMessageWithoutReplayingAfterLeaving() async {
        let center = RecordingNotificationCenter(), adapter = TelegramNotifications(), provider = TelegramDeliveryProvider()
        let manager = NotificationManager(client: center); adapter.manager = manager
        var focused = true
        adapter.isFocused = { $0.chat == 1 && focused }
        let value = snapshot(), item = value.attention.notifications.items[0]
        XCTAssertFalse(item.viewed, "The new message is below the viewport")
        adapter.receive(value, provider: provider); await settle(manager)
        XCTAssertTrue(center.submitted.isEmpty)
        let consumed = await provider.consumed
        XCTAssertTrue(consumed.contains(item.id))
        XCTAssertEqual(adapter.current.count, 1, "In-feed attention is preserved")
        focused = false
        adapter.receive(value, provider: provider); await settle(manager)
        XCTAssertTrue(center.submitted.isEmpty)
    }

    func testUnfocusedChatDeliversAndFocusIsRecheckedAfterAuthorizationAndAtPresentation() async throws {
        for focusDuringAuthorization in [false, true] {
            let center = RecordingNotificationCenter(), adapter = TelegramNotifications(), provider = TelegramDeliveryProvider()
            let manager = NotificationManager(client: center); adapter.manager = manager
            var focused = false
            adapter.isFocused = { _ in focused }
            center.status = .unknown; center.suspendAuthorization = true
            let value = snapshot(), id = value.attention.notifications.items[0].id
            adapter.receive(value, provider: provider)
            for _ in 0..<1000 where center.authorizationContinuation == nil { await Task.yield() }
            XCTAssertNotNil(center.authorizationContinuation)
            focused = focusDuringAuthorization
            center.authorizationContinuation?.resume(returning: true); center.authorizationContinuation = nil
            await settle(manager)
            XCTAssertEqual(center.submitted.count, focusDuringAuthorization ? 0 : 1)
            if !focusDuringAuthorization {
                XCTAssertEqual(manager.presentationOptions(id: id, sound: true), [.banner, .sound])
                focused = true
                XCTAssertTrue(manager.presentationOptions(id: id, sound: true).isEmpty)
            }
        }
    }

    private func snapshot(live: Bool = true) -> TelegramChatSnapshot {
        let id = TelegramChatID(environment: .test, account: 42, chat: 1)
        var value = TelegramChatSnapshot(); value.account = id.root; value.state = .complete
        value.attention.notifications.initialized = true
        value.attention.notifications.items = [.init(id: "telegram:test:42:notification:1:1", destination: id, message: 100,
            kind: .mention, count: 3, date: 1000, sound: true, mayDeliver: live)]
        return value
    }
    private func settle(_ manager: NotificationManager) async {
        for _ in 0..<20 { await Task.yield() }
        await manager.drain()
    }
    func testRestorationIsSilentAndLiveDeliveryIsPrivateAndNavigatesWithoutReading() async throws {
        let center = RecordingNotificationCenter(), adapter = TelegramNotifications(), provider = TelegramDeliveryProvider()
        let manager = NotificationManager(client: center); adapter.manager = manager
        let value = snapshot(), id = value.attention.notifications.items[0].id
        center.delivered = [id, "telegram:test:42:obsolete", "unrelated"]
        adapter.receive(snapshot(live: false), provider: provider); await settle(manager)
        XCTAssertTrue(center.submitted.isEmpty); XCTAssertTrue(center.delivered.contains(id))
        XCTAssertFalse(center.delivered.contains("telegram:test:42:obsolete")); XCTAssertTrue(center.delivered.contains("unrelated"))
        var fresh = value; fresh.attention.notifications.items[0].id = "telegram:test:42:notification:1:2"
        adapter.receive(fresh, provider: provider); await settle(manager)
        XCTAssertEqual(center.submitted.count, 1)
        XCTAssertEqual(center.submitted[0].title, "Telegram")
        XCTAssertEqual(center.submitted[0].body, "New message · 3 addressed messages")
        XCTAssertEqual(center.submitted[0].userInfo, ["locator": fresh.attention.notifications.items[0].id])
        var opened: TelegramAttentionSummary?
        adapter.open = { opened = $0; return true }
        XCTAssertTrue(adapter.activate(fresh.attention.notifications.items[0].id))
        XCTAssertEqual(opened?.firstMessage, 100)
        XCTAssertEqual(adapter.current.count, 1)
        adapter.receive(fresh, provider: provider); await settle(manager)
        XCTAssertEqual(center.submitted.count, 1)
    }
    func testReadOrLogoutDuringAddRevokesLateBannerAndSoundPreferencesHold() async throws {
        let center = RecordingNotificationCenter(), adapter = TelegramNotifications(), provider = TelegramDeliveryProvider()
        let manager = NotificationManager(client: center); adapter.manager = manager
        adapter.preferences = { .init(sound: false) }; center.suspendAdd = true
        adapter.receive(snapshot(), provider: provider)
        for _ in 0..<200 where center.addContinuation == nil { await Task.yield() }
        XCTAssertNotNil(center.addContinuation)
        XCTAssertFalse(try XCTUnwrap(center.submitted.first).sound)
        adapter.disconnect()
        center.addContinuation?.resume(); center.addContinuation = nil
        await settle(manager)
        XCTAssertTrue(center.delivered.isEmpty)
    }
    func testNotificationClickWaitsForTelegramSnapshotAndNeverTouchesLedger() {
        let ledger = AttentionLedger()
        let navigation = NotificationNavigation(ledger: ledger)
        var initialized = false, opened = 0
        navigation.telegramReady = { initialized }; navigation.telegramActivate = { _ in opened += 1; return true }
        navigation.activate("telegram:test:42:notification:1:1"); navigation.finishStartup()
        XCTAssertEqual(opened, 0)
        initialized = true; navigation.retryPending()
        XCTAssertEqual(opened, 1); XCTAssertTrue(ledger.events.isEmpty)
    }
}
