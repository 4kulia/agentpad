import Foundation
import XCTest
@testable import AgentPadTelegram

final class TelegramSponsoredMediaTests: XCTestCase {
    private func file(_ id: Int64 = 41, size: Int64 = 32, path: String? = nil, complete: Bool = false) -> TDLibValue {
        .typed("file", ["id": .integer(id), "size": .integer(size), "expected_size": .integer(size),
            "local": .typed("localFile", ["path": .string(path ?? ""), "is_downloading_completed": .bool(complete), "is_downloading_active": .bool(!complete), "downloaded_size": .integer(complete ? size : 0)])])
    }
    private func disk(_ h: TelegramFeedHarness) throws -> URL {
        let source = h.fixture.directory.appendingPathComponent("files", isDirectory: true)
        try TelegramProfileStore.createDirectory(source)
        h.session.sponsoredDisk = try TelegramSponsoredDiskCache(root: h.fixture.directory.appendingPathComponent("sponsored", isDirectory: true), source: source)
        return source
    }
    func testTextPhotoVideoAnimationAndRecommendedDecodeWithoutOrdinaryRows() throws {
        let h = try TelegramFeedHarness()
        for kind in ["messageText", "messagePhoto", "messageVideo", "messageAnimation"] {
            let raw = try XCTUnwrap(h.ad(kind: kind, file: kind == "messageText" ? nil : file()).object)
            let decoded = try XCTUnwrap(TelegramSponsoredDecoder.decode(raw, result: UUID()))
            XCTAssertEqual(decoded.message.text, "The complete sponsored text")
            XCTAssertEqual(decoded.message.sponsorInfo, "Exact sponsor information")
            XCTAssertEqual(decoded.message.additionalInfo, "Paid promotion")
            XCTAssertEqual(decoded.message.button, "Explore the guides")
            XCTAssertEqual(decoded.message.fullyLoaded, kind == "messageText")
            XCTAssertEqual(decoded.files.count, kind == "messageText" ? 0 : 1)
        }
        var raw = h.ad().object!; raw["is_recommended"] = .bool(true)
        XCTAssertTrue(TelegramSponsoredDecoder.decode(raw, result: UUID())!.message.recommended)
    }
    func testSingleDownloadSharedAcrossPanesAndViewsWaitForWholeMedia() throws {
        let h = try TelegramFeedHarness(), source = try disk(h)
        let ref = try h.readyAd(h.ad(kind: "messagePhoto", file: file()))
        h.showAds([ref], loaded: false); let pane = UUID(); _ = h.session.subscribe(h.id, pane: pane); h.showAds([ref], loaded: false, pane: pane)
        XCTAssertEqual(h.client.requests.filter { $0.type == "downloadFile" }.count, 1)
        XCTAssertFalse(h.client.requests.contains { $0.type == "viewMessages" })
        let path = source.appendingPathComponent("photo.jpg")
        try Data(repeating: 1, count: 32).write(to: path)
        try h.answer("downloadFile", file(path: path.path, complete: true).object!)
        let ad = try XCTUnwrap(h.feed.snapshot.sponsored.messages.first)
        XCTAssertTrue(ad.fullyLoaded)
        let url = try XCTUnwrap(ad.media.first?.url)
        XCTAssertTrue(url.path.hasPrefix(h.fixture.directory.appendingPathComponent("sponsored").path))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        h.showAds([ref], loaded: false); h.showAds([ref], loaded: false, pane: pane)
        XCTAssertFalse(h.client.requests.contains { $0.type == "viewMessages" })
        h.showAds([ref]); try h.answer("viewMessages")
        XCTAssertTrue(h.feed.viewed.isEmpty)
        h.session.sponsoredAction(h.id, epoch: h.epoch, action: .cancelMedia(ref)) { _ in }
        XCTAssertFalse(h.feed.snapshot.sponsored.messages[0].fullyLoaded)
        XCTAssertNotNil(h.feed.snapshot.sponsored.messages[0].media[0].error)
    }
    func testSharedTwoDownloadLimitCancellationAndRetryAreExplicit() throws {
        let h = try TelegramFeedHarness(); _ = try disk(h)
        let ref = try h.readyAd(h.ad(kind: "messagePhoto", file: file()))
        h.session.downloads = [1: 202, 2: 202]
        h.showAds([ref]); XCTAssertFalse(h.client.requests.contains { $0.type == "downloadFile" })
        h.session.downloads[2] = nil; h.session.reconcileSponsoredDownloads()
        XCTAssertEqual(h.client.requests.filter { $0.type == "downloadFile" }.count, 1)
        try h.answer("downloadFile", file().object!)
        h.session.sponsoredAction(h.id, epoch: h.epoch, action: .cancelMedia(ref)) { _ in }
        XCTAssertNotNil(h.feed.snapshot.sponsored.messages.first?.media.first?.error)
        XCTAssertFalse(h.feed.snapshot.sponsored.messages.first!.fullyLoaded)
        try h.answer("cancelDownloadFile")
        h.session.reconcileSponsoredDownloads()
        XCTAssertEqual(h.client.requests.filter { $0.type == "downloadFile" }.count, 1)
        h.session.sponsoredAction(h.id, epoch: h.epoch, action: .retryMedia(ref)) { _ in }
        XCTAssertEqual(h.client.requests.filter { $0.type == "downloadFile" }.count, 2)
        h.showAds(shown: false)
        XCTAssertTrue(h.session.sponsoredDownload?.cancelling == true)
    }
    func testOversizeKnownAndGrowingFilesRemainAdErrors() throws {
        let h = try TelegramFeedHarness()
        let ref = try h.readyAd(h.ad(kind: "messagePhoto", file: file(size: 51 * 1024 * 1024)))
        h.showAds([ref])
        XCTAssertFalse(h.client.requests.contains { $0.type == "downloadFile" })
        XCTAssertNotNil(h.feed.snapshot.sponsored.messages.first?.media.first?.error)
        let other = try TelegramFeedHarness(); _ = try disk(other)
        let otherRef = try other.readyAd(other.ad(kind: "messageVideo", file: file()))
        other.showAds([otherRef]); try other.answer("downloadFile", file().object!)
        other.update("updateFile", ["file": file(size: 51 * 1024 * 1024)])
        XCTAssertTrue(other.session.sponsoredDownload?.cancelling == true)
        XCTAssertNotNil(other.feed.snapshot.sponsored.messages.first?.media.first?.error)
    }
    func testDiskBudgetEvictsUnpinnedFilesAndRejectsSymlinks() throws {
        let h = try TelegramFeedHarness(), source = try disk(h), cache = try XCTUnwrap(h.session.sponsoredDisk)
        for id in 1...3 {
            let url = source.appendingPathComponent("\(id).mp4")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let file = try FileHandle(forWritingTo: url); try file.truncate(atOffset: 50 * 1024 * 1024); try file.close()
        }
        _ = try cache.importFile(1, path: source.appendingPathComponent("1.mp4").path, pinned: [])
        _ = try cache.importFile(2, path: source.appendingPathComponent("2.mp4").path, pinned: [1])
        XCTAssertThrowsError(try cache.importFile(3, path: source.appendingPathComponent("3.mp4").path, pinned: [1, 2]))
        _ = try cache.importFile(3, path: source.appendingPathComponent("3.mp4").path, pinned: [2])
        XCTAssertNil(cache.url(1)); XCTAssertNotNil(cache.url(2)); XCTAssertLessThanOrEqual(cache.bytes, 128 * 1024 * 1024)
        let symlink = source.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source.appendingPathComponent("1.mp4"))
        XCTAssertThrowsError(try cache.importFile(4, path: symlink.path, pinned: []))
    }
    func testMediaClicksUseActualFlagsAndExpandIsNotAClick() throws {
        for (kind, target, media, fullscreen) in [("messagePhoto", TelegramSponsoredClick.media, true, false),
            ("messageVideo", .media, true, false), ("messageVideo", .silentVideoMedia, true, false),
            ("messageVideo", .fullscreenMedia, true, true), ("messageVideo", .fullscreenButton, false, true)] {
            let h = try TelegramFeedHarness(), source = try disk(h)
            let path = source.appendingPathComponent("file.mp4"); try Data(repeating: 1, count: 32).write(to: path)
            let ref = try h.readyAd(h.ad(kind: kind, file: file(path: path.path, complete: true)))
            h.showAds([ref], loaded: false)
            var result: TelegramSponsoredActionResult?
            if kind == "messageVideo" {
                h.session.sponsoredAction(h.id, epoch: h.epoch, action: .click(ref, .expandVideo, confirmed: false)) { result = $0 }
                XCTAssertEqual(result, .fullscreen(ref)); XCTAssertFalse(h.client.requests.contains { $0.type == "clickChatSponsoredMessage" })
            }
            h.session.sponsoredAction(h.id, epoch: h.epoch, action: .click(ref, target, confirmed: true)) { result = $0 }
            let sent = try h.answer("clickChatSponsoredMessage")
            XCTAssertEqual(sent["is_media_click"], .bool(media)); XCTAssertEqual(sent["from_fullscreen"], .bool(fullscreen))
            if kind == "messageVideo" && target == .media { XCTAssertEqual(result, .fullscreen(ref)) }
            else { XCTAssertEqual(result, .openURL(URL(string: "https://example.com/guides")!)) }
        }
    }
    func testCancellationBypassesServerWaitAndSaturatedInteractiveSlots() throws {
        let h = try TelegramFeedHarness(); _ = try disk(h)
        let ref = try h.readyAd(h.ad(kind: "messageVideo", file: file()))
        h.showAds([ref], loaded: false); try h.answer("downloadFile", file().object!)
        h.session.externalInteractive = { 6 }; h.session.retryAt = h.now.addingTimeInterval(60)
        h.session.sponsoredAction(h.id, epoch: h.epoch, action: .cancelMedia(ref)) { _ in }
        XCTAssertTrue(h.session.sponsoredDownload?.cancelling == true)
        try h.answer("cancelDownloadFile")
        XCTAssertNil(h.session.sponsoredDownload)
    }
    func testManySmallFilesCannotGrowCacheMetadataWithoutBound() throws {
        let h = try TelegramFeedHarness(), source = try disk(h), cache = try XCTUnwrap(h.session.sponsoredDisk)
        let url = source.appendingPathComponent("small.jpg"); try Data(repeating: 1, count: 32).write(to: url)
        for id in 1...260 { _ = try cache.importFile(Int64(id), path: url.path, pinned: []) }
        XCTAssertEqual(cache.items.count, 256)
        XCTAssertNil(cache.url(1)); XCTAssertNotNil(cache.url(260))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.root.path).count, 256)
    }
}
