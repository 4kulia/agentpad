import Foundation
import XCTest
@testable import AgentPadTelegram

extension TelegramFeedHarness {
    func ad(_ id: Int64 = 900, kind: String = "messageText", file: TDLibValue? = nil, report: Bool = true) -> TDLibValue {
        var content: [String: TDLibValue] = [kind == "messageText" ? "text" : "caption": .typed("formattedText", ["text": .string("The complete sponsored text"), "entities": .array([])])]
        if let file {
            let dimensions: [String: TDLibValue] = ["width": .integer(20), "height": .integer(20), "photo": file]
            if kind == "messagePhoto" { content["photo"] = .typed("photo", ["sizes": .array([.typed("photoSize", dimensions)])]) }
            else { let field = kind == "messageVideo" ? "video" : "animation"; content[field] = .typed(field, ["width": .integer(20), "height": .integer(20), field: file]) }
        }
        return .typed("sponsoredMessage", ["message_id": .integer(id), "is_recommended": .bool(false), "can_be_reported": .bool(report),
            "content": .typed(kind, content), "sponsor": .typed("advertisementSponsor", ["url": .string("https://example.com/guides"), "info": .string("Exact sponsor information")]),
            "title": .string("Quiet Atlas"), "button_text": .string("Explore the guides"), "accent_color_id": .integer(5), "additional_info": .string("Paid promotion")])
    }
    func ads(_ messages: [TDLibValue], spacing: Int64 = 0) -> TDLibMessage { .init("sponsoredMessages", ["messages": .array(messages), "messages_between": .integer(spacing)]) }
    func showAds(_ refs: [TelegramSponsoredRef] = [], loaded: Bool = true, full: Bool = true, active: Bool = true, shown: Bool = true, pane: UUID? = nil) {
        observe(id, .init(pane: pane ?? self.pane, epoch: epoch, active: active, shown: shown, ordinaryIDs: [],
            sponsored: refs.map { .init(ref: $0, fullyLoaded: loaded, fullTextVisible: full) }, sponsoredRequests: Set(refs)))
    }
    func readyAd(_ value: TDLibValue? = nil) throws -> TelegramSponsoredRef {
        channel(); showAds(); try answer("openChat"); try answer("getChatSponsoredMessages", ads([value ?? ad()]))
        return try XCTUnwrap(session.sponsored[id.chat]?.snapshot.messages.first?.ref)
    }
}

final class TelegramSponsoredTests: XCTestCase {
    func testOpeningPanesSharesFetchAndFiveMinuteCacheIncludingEmpty() throws {
        for empty in [false, true] {
            let h = try TelegramFeedHarness(); h.channel(); h.showAds()
            let pane = UUID(); _ = h.session.subscribe(h.id, pane: pane); h.showAds(pane: pane)
            XCTAssertEqual(h.client.requests.filter { $0.type == "getChatSponsoredMessages" }.count, 1)
            try h.answer("getChatSponsoredMessages", h.ads(empty ? [] : [h.ad()]))
            h.showAds(shown: false); h.showAds(shown: false, pane: pane)
            h.session.now = h.now.addingTimeInterval(299); h.showAds()
            XCTAssertEqual(h.client.requests.filter { $0.type == "getChatSponsoredMessages" }.count, 1)
            XCTAssertEqual(h.feed.snapshot.sponsored.state, empty ? .empty : .ready)
            h.session.now = h.now.addingTimeInterval(301); h.session.reconcileSponsored()
            XCTAssertEqual(h.client.requests.filter { $0.type == "getChatSponsoredMessages" }.count, 2)
            XCTAssertEqual(h.feed.snapshot.sponsored.state, .loading)
            XCTAssertTrue(h.feed.snapshot.sponsored.messages.isEmpty)
        }
    }
    func testErrorBackoffAndTimeoutDoNotBecomeEmptyOrDuplicateInFlight() throws {
        let h = try TelegramFeedHarness(); h.channel(); h.showAds()
        try h.answer("getChatSponsoredMessages", .init("error", ["code": .integer(429), "message": .string("retry after 12")]))
        XCTAssertEqual(h.feed.snapshot.sponsored.state, .error)
        XCTAssertGreaterThan(h.feed.snapshot.sponsored.retryNotBefore, h.now)
        h.session.sponsoredAction(h.id, epoch: h.epoch, action: .retry) { _ in }
        XCTAssertEqual(h.client.requests.filter { $0.type == "getChatSponsoredMessages" }.count, 1)
        h.session.now = h.now.addingTimeInterval(20)
        h.session.sponsoredAction(h.id, epoch: h.epoch, action: .retry) { _ in }
        h.session.tick(now: h.now.addingTimeInterval(61), uptime: 71)
        XCTAssertEqual(h.feed.snapshot.sponsored.state, .error)
        h.session.sponsoredAction(h.id, epoch: h.epoch, action: .retry) { _ in }
        XCTAssertEqual(h.client.requests.filter { $0.type == "getChatSponsoredMessages" }.count, 2)
    }
    func testOnlyFullReadyActiveUncoveredTextIsViewedAndDeduplicatedAcrossPanes() throws {
        let h = try TelegramFeedHarness(), ref = try h.readyAd()
        for (loaded, full, active, shown) in [(false, true, true, true), (true, false, true, true), (true, true, false, true), (true, true, true, false)] {
            h.showAds([ref], loaded: loaded, full: full, active: active, shown: shown)
        }
        // Settle close/open service bookkeeping before checking the impression.
        if h.client.requests.contains(where: { $0.type == "closeChat" }) { try h.answer("closeChat") }
        XCTAssertFalse(h.client.requests.contains { $0.type == "viewMessages" })
        h.showAds([ref]); if h.session.calls.values.contains(where: \.service) { try h.answer("openChat") }
        h.session.reconcileSponsored()
        let pane = UUID(); _ = h.session.subscribe(h.id, pane: pane); h.showAds([ref], pane: pane)
        let request = try h.answer("viewMessages")
        XCTAssertEqual(request["message_ids"], .array([.integer(ref.message)]))
        XCTAssertEqual(request["source"]?.object?.type, "messageSourceChatHistory")
        XCTAssertEqual(request["force_read"], .bool(false))
        h.showAds([ref]); h.showAds([ref], pane: pane)
        XCTAssertEqual(h.client.requests.filter { $0.type == "viewMessages" }.count, 1)
        XCTAssertEqual(h.feed.snapshot.inbox, 0); XCTAssertTrue(h.feed.viewed.isEmpty); XCTAssertTrue(h.feed.snapshot.messages.isEmpty)
    }
    func testFailedViewNeedsNewVisibilityAndHasBoundedRetries() throws {
        let h = try TelegramFeedHarness(), ref = try h.readyAd()
        h.showAds([ref]); try h.answer("viewMessages", .init("error"))
        h.session.now = h.now.addingTimeInterval(10)
        h.showAds([ref]); h.session.reconcileSponsored()
        XCTAssertEqual(h.client.requests.filter { $0.type == "viewMessages" }.count, 1)
        for attempt in 2...4 {
            h.showAds([]); h.showAds([ref])
            XCTAssertEqual(h.client.requests.filter { $0.type == "viewMessages" }.count, min(attempt, 3))
            if attempt < 4 { try h.answer("viewMessages", .init("error")); h.session.now += 10 }
        }
    }
    func testClosedChatsDoNotPollAndLateLogoutResponseIsIgnored() throws {
        let h = try TelegramFeedHarness(); _ = try h.readyAd()
        h.showAds(shown: false); h.session.now += 301; h.session.reconcileSponsored()
        XCTAssertEqual(h.client.requests.filter { $0.type == "getChatSponsoredMessages" }.count, 1)
        h.showAds(); let request = try XCTUnwrap(h.client.requests.last { $0.type == "getChatSponsoredMessages" })
        h.session.stop()
        var response = h.ads([h.ad()]); response["@extra"] = request["@extra"]
        h.session.receive(response, now: h.session.now, uptime: 400)
        XCTAssertTrue(h.session.sponsored.isEmpty)
    }
    func testClickOnlyAfterExplicitConfirmedActionAndExpiredActionRejected() throws {
        let h = try TelegramFeedHarness(), ref = try h.readyAd()
        var result: TelegramSponsoredActionResult?
        h.session.sponsoredAction(h.id, epoch: h.epoch, action: .click(ref, .button, confirmed: false)) { result = $0 }
        XCTAssertEqual(result, .confirmURL(URL(string: "https://example.com/guides")!))
        XCTAssertFalse(h.client.requests.contains { $0.type == "clickChatSponsoredMessage" })
        h.session.sponsoredAction(h.id, epoch: h.epoch, action: .click(ref, .button, confirmed: true)) { result = $0 }
        let request = try h.answer("clickChatSponsoredMessage")
        XCTAssertEqual(request["is_media_click"], .bool(false)); XCTAssertEqual(request["from_fullscreen"], .bool(false))
        XCTAssertEqual(result, .openURL(URL(string: "https://example.com/guides")!))
        h.session.now += 301
        h.session.sponsoredAction(h.id, epoch: h.epoch, action: .click(ref, .button, confirmed: true)) { result = $0 }
        guard case .error = result else { return XCTFail("Expired ad allowed") }
    }
    func testMultiStepReportUsesOpaqueOptionsAndHandlesEveryTerminalResult() throws {
        for terminal in ["reportSponsoredResultOk", "reportSponsoredResultFailed", "reportSponsoredResultAdsHidden", "reportSponsoredResultPremiumRequired"] {
            let h = try TelegramFeedHarness(), ref = try h.readyAd()
            var result: TelegramSponsoredActionResult?
            h.session.sponsoredAction(h.id, epoch: h.epoch, action: .report(ref, step: nil, option: nil)) { result = $0 }
            let opaque = Data([0, 255, 128, 12]).base64EncodedString()
            let options = TDLibMessage("reportSponsoredResultOptionRequired", ["title": .string("Server reason"), "options": .array([.typed("reportOption", ["id": .string(opaque), "text": .string("Server choice")])])])
            XCTAssertEqual(try h.answer("reportChatSponsoredMessage", options)["option_id"], .string(""))
            guard case .reportOptions(_, let step, let title, let choices) = result else { return XCTFail("Missing choices") }
            XCTAssertEqual(title, "Server reason"); XCTAssertEqual(choices.map(\.id), [opaque])
            h.session.sponsoredAction(h.id, epoch: h.epoch, action: .report(ref, step: UUID(), option: opaque)) { result = $0 }
            guard case .error = result else { return XCTFail("Stale choice allowed") }
            h.session.sponsoredAction(h.id, epoch: h.epoch, action: .report(ref, step: step, option: opaque)) { result = $0 }
            XCTAssertEqual(try h.answer("reportChatSponsoredMessage", .init(terminal))["option_id"], .string(opaque))
            guard case .notice = result else { return XCTFail("Missing server outcome") }
            XCTAssertFalse(h.client.requests.contains { $0.type == "clickChatSponsoredMessage" })
            XCTAssertEqual(h.feed.snapshot.sponsored.messages.count, terminal == "reportSponsoredResultPremiumRequired" ? 1 : 0)
        }
    }
    func testUnsafeURLsAndTrustedDomainBoundaries() {
        for raw in ["file:///tmp/ad", "javascript:alert(1)", "custom://test", "https://user:secret@example.com", "https://example.com\n/x"] { XCTAssertNil(TelegramSponsoredURL.checked(raw)) }
        for host in ["t.me", "telegram.org", "sub.telegram.me", "telegra.ph", "te.legra.ph", "fragment.com"] {
            XCTAssertFalse(TelegramSponsoredURL.requiresConfirmation(URL(string: "https://" + host)!))
        }
        for host in ["t.me.evil.example", "nottelegram.org", "example.com", "telegram.org:1234"] {
            XCTAssertTrue(TelegramSponsoredURL.requiresConfirmation(URL(string: "https://" + host)!))
        }
    }
    func testTrustedTelegramDestinationOpensInAppWithoutJoiningOrSending() throws {
        let h = try TelegramFeedHarness()
        var raw = h.ad().object!
        raw["sponsor"] = .typed("advertisementSponsor", ["url": .string("https://t.me/quiet_atlas")])
        let ref = try h.readyAd(.object(raw.fields))
        var result: TelegramSponsoredActionResult?
        h.session.sponsoredAction(h.id, epoch: h.epoch, action: .click(ref, .title, confirmed: false)) { result = $0 }
        try h.answer("clickChatSponsoredMessage")
        try h.answer("getInternalLinkType", .init("internalLinkTypePublicChat", ["chat_username": .string("quiet_atlas")]))
        try h.answer("searchPublicChat", .init("chat", ["id": .integer(-444)]))
        XCTAssertEqual(result, .openChat(.init(environment: .test, account: 101, chat: -444)))
        XCTAssertFalse(h.client.requests.contains { ["joinChat", "sendMessage", "sendBotStartMessage"].contains($0.type) })
    }
    func testServerControlsReportingAndCancellationDoesNotHideTheAd() throws {
        let h = try TelegramFeedHarness(), ref = try h.readyAd(h.ad(report: false))
        var result: TelegramSponsoredActionResult?
        h.session.sponsoredAction(h.id, epoch: h.epoch, action: .report(ref, step: nil, option: nil)) { result = $0 }
        guard case .error = result else { return XCTFail("Unreportable ad was reported") }
        XCTAssertFalse(h.client.requests.contains { $0.type == "reportChatSponsoredMessage" })
        h.session.sponsoredAction(h.id, epoch: h.epoch, action: .cancelReport(ref)) { _ in }
        XCTAssertEqual(h.feed.snapshot.sponsored.messages.count, 1)
    }
    func testClosedLateFetchKeepsFiveMinutesFromReceiptAndRetryBecomesAvailable() throws {
        let h = try TelegramFeedHarness(); h.channel(); h.showAds(); h.showAds(shown: false)
        h.session.now += 200
        try h.answer("getChatSponsoredMessages", h.ads([]))
        h.session.now += 101; h.session.reconcileSponsored(); h.showAds()
        XCTAssertEqual(h.feed.snapshot.sponsored.state, .empty)
        XCTAssertEqual(h.client.requests.filter { $0.type == "getChatSponsoredMessages" }.count, 1)
        h.session.now += 200; h.session.reconcileSponsored()
        try h.answer("getChatSponsoredMessages", .init("error"))
        XCTAssertGreaterThan(h.feed.snapshot.sponsored.retryNotBefore, h.session.now)
        h.session.now += 61; h.session.reconcileSponsored()
        XCTAssertEqual(h.feed.snapshot.sponsored.retryNotBefore, .distantPast)
    }
}
