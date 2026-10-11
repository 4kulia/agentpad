import XCTest
@testable import AgentPadTelegram

final class TelegramPresentationTests: XCTestCase {
    private func observation(_ h: TelegramFeedHarness, ref: TelegramSponsoredRef, positive: Bool,
                             pane: UUID? = nil) -> TelegramPresentationObservation {
        .init(pane: pane ?? h.pane, epoch: h.epoch, active: true, shown: true, ordinaryIDs: positive ? [10] : [],
              sponsored: [.init(ref: ref, fullyLoaded: true, fullTextVisible: positive)])
    }

    func testUnpublishedObservationsCannotReadMessagesOrCountImpressions() throws {
        let h = try TelegramFeedHarness(), ref = try h.readyAd()
        h.session.merge(h.message(10), into: h.feed)
        let value = observation(h, ref: ref, positive: true)
        XCTAssertFalse(value.isCurrent)
        h.session.observation(h.id, value)
        XCTAssertFalse(h.client.requests.contains { $0.type == "viewMessages" })
    }

    func testFastScrollInvalidatesPositiveBeforeBusyConnectorReceivesEitherSnapshot() throws {
        let h = try TelegramFeedHarness(), ref = try h.readyAd(), observations = TelegramPresentationObservations()
        h.session.merge(h.message(10), into: h.feed)
        let positive = observations.record(observation(h, ref: ref, positive: true))
        let negative = observations.record(observation(h, ref: ref, positive: false))
        XCTAssertGreaterThan(negative.generation, positive.generation)
        h.session.observation(h.id, positive)
        h.session.reconcilePresentation(h.feed); h.session.reconcileSponsored()
        XCTAssertFalse(h.client.requests.contains { $0.type == "viewMessages" })
        // Reversed delivery must not restore the older positive either.
        h.session.observation(h.id, negative); h.session.observation(h.id, positive)
        XCTAssertEqual(h.feed.observations[h.pane]?.generation, negative.generation)
        XCTAssertFalse(h.client.requests.contains { $0.type == "viewMessages" })
        h.session.observation(h.id, observations.record(observation(h, ref: ref, positive: true)))
        XCTAssertEqual(try h.answer("viewMessages")["message_ids"], .array([.integer(10)]))
        h.session.reconcileSponsored()
        XCTAssertEqual(try h.answer("viewMessages")["message_ids"], .array([.integer(ref.message)]))
        XCTAssertEqual(h.feed.viewed, [10])
    }

    func testQueuedViewsAreInvalidatedEvenBeforeNegativeReachesConnector() throws {
        let h = try TelegramFeedHarness(), ref = try h.readyAd(), observations = TelegramPresentationObservations()
        h.session.merge(h.message(10), into: h.feed)
        XCTAssertTrue(h.session.request("setOption", service: true)) // Occupied service lane.
        h.session.observation(h.id, observations.record(observation(h, ref: ref, positive: true)))
        _ = observations.record(observation(h, ref: ref, positive: false))
        try h.answer("setOption")
        h.session.reconcilePresentation(h.feed); h.session.reconcileSponsored()
        XCTAssertFalse(h.client.requests.contains { $0.type == "viewMessages" })
        XCTAssertTrue(h.feed.viewPending.isEmpty)
        XCTAssertTrue(h.session.sponsored[h.id.chat]!.pendingViews.isEmpty)
    }

    func testQueuedViewsStayInvalidWhileCoalescedGeometryIsPending() throws {
        let h = try TelegramFeedHarness(), ref = try h.readyAd(), observations = TelegramPresentationObservations()
        h.session.merge(h.message(10), into: h.feed)
        XCTAssertTrue(h.session.request("setOption", service: true))
        h.session.observation(h.id, observations.record(observation(h, ref: ref, positive: true)))
        // A geometry update revokes the old result without publishing a new
        // observation until the main run loop evaluates the latest geometry.
        observations.invalidate(pane: h.pane)
        try h.answer("setOption")
        h.session.reconcilePresentation(h.feed); h.session.reconcileSponsored()
        XCTAssertFalse(h.client.requests.contains { $0.type == "viewMessages" })
        XCTAssertTrue(h.feed.viewPending.isEmpty)
        XCTAssertTrue(h.session.sponsored[h.id.chat]!.pendingViews.isEmpty)
        h.session.observation(h.id, observations.record(observation(h, ref: ref, positive: true)))
        XCTAssertEqual(try h.answer("viewMessages")["message_ids"], .array([.integer(10)]))
        h.session.reconcileSponsored()
        XCTAssertEqual(try h.answer("viewMessages")["message_ids"], .array([.integer(ref.message)]))
    }

    func testBothRPCPathsRecheckGenerationAfterSelectingCandidates() throws {
        for sponsored in [false, true] {
            let h = try TelegramFeedHarness(), ref = try h.readyAd(), observations = TelegramPresentationObservations()
            h.session.merge(h.message(10), into: h.feed)
            let positive = observations.record(observation(h, ref: ref, positive: true))
            h.feed.observations[h.pane] = positive
            // request checks the scheduler after the reducer has selected its
            // batch. Publish a scroll-away there, without delivering its Task.
            h.session.accountRetryAt = {
                _ = observations.record(self.observation(h, ref: ref, positive: false))
                return .distantPast
            }
            if sponsored { h.session.reconcileSponsoredViews(h.id.chat, entry: h.session.sponsored[h.id.chat]!) }
            else { h.session.reconcilePresentation(h.feed) }
            XCTAssertFalse(h.client.requests.contains { $0.type == "viewMessages" })
            XCTAssertTrue(h.feed.viewPending.isEmpty)
            XCTAssertTrue(h.session.sponsored[h.id.chat]!.pendingViews.isEmpty)
            h.session.accountRetryAt = { .distantPast }
        }
    }

    func testGenerationsAreIndependentAcrossPanesAndInvalidatedOnTeardown() throws {
        let h = try TelegramFeedHarness(), ref = try h.readyAd(), observations = TelegramPresentationObservations(), second = UUID()
        let first = observations.record(observation(h, ref: ref, positive: true))
        let other = observations.record(observation(h, ref: ref, positive: true, pane: second))
        XCTAssertTrue(first.isCurrent); XCTAssertTrue(other.isCurrent)
        observations.invalidate(pane: h.pane)
        XCTAssertFalse(first.isCurrent); XCTAssertTrue(other.isCurrent)
        observations.invalidateAll()
        XCTAssertFalse(other.isCurrent)
    }
}
