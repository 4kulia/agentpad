import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

@MainActor final class TelegramSponsoredUITests: XCTestCase {
    private let id = TelegramChatID(environment: .test, account: 101, chat: 202)
    private func snapshot(spacing: Int = 0, count: Int = 12) -> TelegramConversationSnapshot {
        var value = TelegramConversationSnapshot(destination: id)
        value.kind = .channel; value.capabilities.canRead = true; value.title = "Harbor Notes"
        value.sponsored.state = .ready; value.sponsored.result = UUID(); value.sponsored.expiresAt = Date().addingTimeInterval(300)
        value.sponsored.messagesBetween = spacing
        for number in 1...3 {
            let raw = TDLibMessage("sponsoredMessage", ["message_id": .integer(Int64(900 + number)), "can_be_reported": .bool(true),
                "title": .string("Quiet Atlas"), "button_text": .string("Explore the guides ↗"), "accent_color_id": .integer(5),
                "sponsor": .typed("advertisementSponsor", ["url": .string("https://example.com/guides"), "info": .string("Sponsored by Quiet Atlas · Example sponsor information")]),
                "additional_info": .string("Discover considered places for your next journey."),
                "content": .typed("messageText", ["text": .typed("formattedText", ["text": .string("A quieter way to find your next destination. Explore independent travel guides, useful local details, and places chosen with care."), "entities": .array([])])])])
            value.sponsored.messages.append(TelegramSponsoredDecoder.decode(raw, result: value.sponsored.result!)!.message)
        }
        for number in 1...count {
            let raw = TDLibMessage("message", ["id": .integer(Int64(number)), "chat_id": .integer(id.chat), "content": .typed("messageText", ["text": .typed("formattedText", ["text": .string("Post \(number)")])])])
            value.messages.append(TelegramMessageDecoder.decode(raw, now: Date(), author: "Harbor Notes")!)
        }
        return value
    }
    func testPlacementAndNamespacesRespectTelegramSpacingAndLatestBoundary() {
        var value = snapshot()
        var rows = TelegramSponsoredLayout.rows(value)
        XCTAssertEqual(rows.count, 13)
        XCTAssertTrue(rows.last!.id.hasPrefix("sponsored:"))
        XCTAssertFalse(Set(value.messages.map(\.id)).contains(rows.last!.id))
        value.hasNewer = true
        XCTAssertEqual(TelegramSponsoredLayout.rows(value).count, 12)
        value.hasNewer = false; value.sponsored.messagesBetween = 3
        rows = TelegramSponsoredLayout.rows(value)
        let positions = rows.enumerated().compactMap { index, row -> Int? in if case .sponsored = row { return index }; return nil }
        XCTAssertEqual(positions, [6, 10, 14]) // Three ordinary rows between every pair.
        value.sponsored.state = .error
        XCTAssertEqual(TelegramSponsoredLayout.rows(value).count, 12)
    }
    func testFullTextRequiresBothDimensionsAndDoesNotReadButtonOrOrdinaryIDs() {
        let viewport = CGRect(x: 0, y: 0, width: 300, height: 100)
        XCTAssertTrue(ConversationFrames.fullyVisible(CGRect(x: 0, y: 5, width: 300, height: 90), viewport: viewport))
        for frame in [CGRect(x: 0, y: -1, width: 200, height: 30), CGRect(x: 0, y: 50, width: 200, height: 51),
                      CGRect(x: -1, y: 20, width: 200, height: 30), CGRect(x: 1, y: 20, width: 300, height: 30), .zero] {
            XCTAssertFalse(ConversationFrames.fullyVisible(frame, viewport: viewport))
        }
        let model = TelegramConversationModel(id: id); model.receive(snapshot())
        XCTAssertFalse(model.canSend); XCTAssertFalse(model.presentation.canSend)
        XCTAssertEqual(model.snapshot.messages.count, 12)
        XCTAssertEqual(model.presentation.rows.count, 13)
        model.sponsoredInfo(model.snapshot.sponsored.messages[0], pane: UUID(), why: false)
        XCTAssertTrue(model.sponsoredDialog!.text.contains("Sponsored by Quiet Atlas"))
        XCTAssertTrue(model.sponsoredDialog!.options.isEmpty)
        let stale = model.sponsoredDialog!.ref
        var replacement = snapshot(); replacement.revision = 2; model.receive(replacement)
        XCTAssertNil(model.currentAd(stale)); XCTAssertNil(model.sponsoredDialog)
    }
    func testActualImageAndAnimationDecodeRejectsBadMediaAndBoundsBuffers() async throws {
        let root = try await fixtureMedia()
        defer { Task.detached { try? FileManager.default.removeItem(at: root) } }
        let decoder = TelegramSponsoredImageDecoder.shared
        let photo = try await decoder.decode(root.appendingPathComponent("photo.png"), kind: .photo)
        XCTAssertEqual(photo.image.width, 24); XCTAssertLessThan(photo.bytes, 64 * 1024 * 1024)
        let animation = try await decoder.decode(root.appendingPathComponent("animation.gif"), kind: .animation)
        XCTAssertEqual(animation.frames, 2)
        let next = try await decoder.decode(root.appendingPathComponent("animation.gif"), kind: .animation, frame: 1)
        XCTAssertEqual(next.image.width, 24)
        let video = try await decoder.decode(root.appendingPathComponent("video.mp4"), kind: .video)
        XCTAssertNotNil(video.movie); XCTAssertFalse(video.hasAudio)
        for name in ["too-wide.png", "broken.png"] {
            do { _ = try await decoder.decode(root.appendingPathComponent(name), kind: .photo); XCTFail("Invalid media accepted") }
            catch {}
        }
    }
    func testSponsorInfoAndCancelledExternalConfirmationDoNotCountAsClicks() async {
        let model = TelegramConversationModel(id: id), fake = ConversationUIFake(), pane = UUID()
        model.receive(snapshot()); model.provider = fake; model.panes.insert(pane)
        let ad = model.snapshot.sponsored.messages[0]
        model.sponsoredInfo(ad, pane: pane, why: true)
        XCTAssertTrue(model.sponsoredDialog?.why == true)
        let initialActions = await fake.sponsoredActions
        XCTAssertTrue(initialActions.isEmpty)
        model.dismissSponsoredDialog()
        await fake.setSponsoredResult(.confirmURL(URL(string: "https://example.com/guides")!))
        model.sponsoredAction(.click(ad.ref, .button, confirmed: false), pane: pane, ref: ad.ref)
        model.sponsoredAction(.click(ad.ref, .button, confirmed: false), pane: pane, ref: ad.ref)
        for _ in 0..<100 { if model.sponsoredDialog != nil { break }; await Task.yield() }
        XCTAssertEqual(model.sponsoredDialog?.title, "Open example.com?")
        model.dismissSponsoredDialog()
        let actions = await fake.sponsoredActions
        XCTAssertEqual(actions.count, 1)
        if case .click(_, _, let confirmed) = actions.first { XCTAssertFalse(confirmed) }
        else { XCTFail("Missing unconfirmed action") }
        var expired = model.snapshot; expired.revision += 1; expired.sponsored.expiresAt = .distantPast; model.receive(expired)
        model.sponsoredAction(.click(ad.ref, .button, confirmed: true), pane: pane, ref: ad.ref)
        await Task.yield()
        let finalActions = await fake.sponsoredActions
        XCTAssertEqual(finalActions.count, 1)
    }
    func testReportStepsKeepThePresentedSheetIdentity() async {
        let model = TelegramConversationModel(id: id), fake = ConversationUIFake(), pane = UUID()
        model.receive(snapshot()); model.provider = fake; model.panes.insert(pane)
        let ref = model.snapshot.sponsored.messages[0].ref, first = UUID(), second = UUID()
        let options = [TelegramSponsoredReportOption(id: "AP8=", text: "Server choice")]
        await fake.setSponsoredResult(.reportOptions(ref, step: first, title: "Reason", options: options))
        model.sponsoredAction(.report(ref, step: nil, option: nil), pane: pane, ref: ref)
        for _ in 0..<100 { if model.sponsoredDialog?.step == first { break }; await Task.yield() }
        let sheet = model.sponsoredDialog?.id
        XCTAssertNotNil(sheet)
        await fake.setSponsoredResult(.reportOptions(ref, step: second, title: "More detail", options: options))
        model.sponsoredAction(.report(ref, step: first, option: options[0].id), pane: pane, ref: ref)
        for _ in 0..<100 { if model.sponsoredDialog?.step == second { break }; await Task.yield() }
        XCTAssertEqual(model.sponsoredDialog?.id, sheet)
        XCTAssertEqual(model.sponsoredDialog?.title, "More detail")
        XCTAssertEqual(model.sponsoredDialog?.step, second)
        XCTAssertFalse(model.sponsoredBusy)
    }
    private func fixtureMedia() async throws -> URL {
        try await Task.detached {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("telegram-media-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            func image(_ width: Int) -> CGImage {
                let context = CGContext(data: nil, width: width, height: 24, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: 24))
                return context.makeImage()!
            }
            for (name, width) in [("photo.png", 24), ("too-wide.png", 8193)] {
                let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, image(width), nil); guard CGImageDestinationFinalize(destination) else { throw TelegramConversationError.files }
            }
            let gif = CGImageDestinationCreateWithURL(root.appendingPathComponent("animation.gif") as CFURL, UTType.gif.identifier as CFString, 2, nil)!
            for _ in 0..<2 { CGImageDestinationAddImage(gif, image(24), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary) }
            guard CGImageDestinationFinalize(gif) else { throw TelegramConversationError.files }
            try Data("invalid image".utf8).write(to: root.appendingPathComponent("broken.png"))
            let writer = try AVAssetWriter(outputURL: root.appendingPathComponent("video.mp4"), fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 24, AVVideoHeightKey: 24])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 24, kCVPixelBufferHeightKey as String: 24])
            writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 24, 24, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw TelegramConversationError.files }
            for index in 0..<2 {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 2)) else { throw TelegramConversationError.files }
            }
            input.markAsFinished(); await writer.finishWriting()
            guard writer.status == .completed else { throw TelegramConversationError.files }
            return root
        }.value
    }
    func testNativeSponsoredCardCapture() async throws {
        guard let output = ProcessInfo.processInfo.environment["AGENTPAD_TELEGRAM_CAPTURE"] else { throw XCTSkip("Opt-in native captures") }
        _ = NSApplication.shared
        let settings = AgentPadSettingsModel.shared, previous = AgentPadSettingsModel.shared.appearanceMode
        defer { settings.appearanceMode = previous }
        for scheme: ColorScheme in [.light, .dark] {
            settings.appearanceMode = scheme == .dark ? .dark : .light
            let ad = snapshot().sponsored.messages[0], coordinate = UUID()
            let content = VStack(alignment: .leading, spacing: 0) {
                Text("Harbor Notes · Channel").font(Theme.display(17, weight: .semibold)).padding(20)
                Divider()
                Text("A weekly collection of thoughtful notes and useful discoveries.").font(Theme.display(13)).padding(20)
                Text("◉ 1,482 views").font(Theme.display(10)).foregroundStyle(.secondary).padding(.horizontal, 20)
                TelegramSponsoredCard(ad: ad, coordinate: coordinate, active: false, action: { _ in }, info: { _ in })
                Spacer()
                Divider()
                Text("Read-only in AgentPad · Open in Telegram to post").font(Theme.display(12)).foregroundStyle(.secondary).padding(16)
            }.frame(width: 760, height: 560).background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground).environment(\.colorScheme, scheme).coordinateSpace(name: coordinate)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let url = URL(fileURLWithPath: output).appendingPathComponent(scheme == .dark ? "channel-dark.png" : "channel-light.png")
            try await Task.detached { try bytes.write(to: url) }.value
            window.contentView = nil; window.close()
        }
    }
}
