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
    func testReportStepsKeepThePresentedPopupIdentity() async {
        let model = TelegramConversationModel(id: id), fake = ConversationUIFake(), pane = UUID()
        model.receive(snapshot()); model.provider = fake; model.panes.insert(pane)
        let ref = model.snapshot.sponsored.messages[0].ref, first = UUID(), second = UUID()
        let options = [TelegramSponsoredReportOption(id: "AP8=", text: "Server choice")]
        await fake.setSponsoredResult(.reportOptions(ref, step: first, title: "Reason", options: options))
        model.sponsoredAction(.report(ref, step: nil, option: nil), pane: pane, ref: ref)
        for _ in 0..<100 { if model.sponsoredDialog?.step == first { break }; await Task.yield() }
        let popup = model.sponsoredDialog?.id
        XCTAssertNotNil(popup)
        await fake.setSponsoredResult(.reportOptions(ref, step: second, title: "More detail", options: options))
        model.sponsoredAction(.report(ref, step: first, option: options[0].id), pane: pane, ref: ref)
        for _ in 0..<100 { if model.sponsoredDialog?.step == second { break }; await Task.yield() }
        XCTAssertEqual(model.sponsoredDialog?.id, popup)
        XCTAssertEqual(model.sponsoredDialog?.title, "More detail")
        XCTAssertEqual(model.sponsoredDialog?.step, second)
        XCTAssertFalse(model.sponsoredBusy)
    }
    func testPopupReportUpdatesInPlaceAndDismissalCancelsOnlyItsReport() async throws {
        let model = TelegramConversationModel(id: id), fake = ConversationUIFake(), pane = UUID(), coordinator = PopupCoordinator()
        model.receive(snapshot()); model.provider = fake; model.panes.insert(pane)
        let ref = model.snapshot.sponsored.messages[0].ref, first = UUID(), second = UUID()
        let option = TelegramSponsoredReportOption(id: "AP8=", text: "Server choice")
        model.sponsoredDialog = .init(epoch: model.snapshot.epoch, pane: pane, ref: ref, title: "Reason",
            text: "Choose the option supplied by Telegram.", step: first, options: [option])
        let dialog = try XCTUnwrap(model.sponsoredDialog)
        let page = try XCTUnwrap(TelegramSponsoredPopup.makePage(model: model, dialog: dialog, pane: pane, coordinator: coordinator))
        coordinator.presentNative(page)
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        let host = FoldersUIHost(Color.clear.popupHost(coordinator), width: 800, height: 650)
        defer { host.close(); coordinator.terminate(); NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        try await host.settle()
        try await assertPopupInventoryPresentation(in: host.window, root: host.view, coordinator: coordinator,
            title: "Sponsored message")
        XCTAssertTrue(host.labels().contains("Reason"))
        XCTAssertTrue(host.labels().contains("Server choice"))
        await fake.setSponsoredResult(.reportOptions(ref, step: second, title: "More detail", options: [option]))
        let content = TelegramSponsoredPopup(model: model, dialogID: dialog.id, pane: pane, openChat: { _ in },
            dismiss: { coordinator.dismiss(page, reason: $0) })
        content.report(option)
        for _ in 0..<100 { if model.sponsoredDialog?.step == second { break }; await Task.yield() }
        try await host.settle()
        XCTAssertEqual(coordinator.page?.id, ObjectIdentifier(page))
        XCTAssertEqual(model.sponsoredDialog?.id, dialog.id)
        XCTAssertTrue(host.labels().contains("More detail"))
        XCTAssertFalse(host.labels().contains("Reason"))
        XCTAssertNil(host.window.attachedSheet)
        coordinator.dismiss(reason: .dismiss)
        for _ in 0..<100 { if await fake.sponsoredActions.count == 2 { break }; await Task.yield() }
        let actions = await fake.sponsoredActions
        XCTAssertEqual(actions.count, 2)
        if case .report(let actualRef, let step, let selected) = actions.first {
            XCTAssertEqual(actualRef, ref); XCTAssertEqual(step, first); XCTAssertEqual(selected, option.id)
        } else { XCTFail("Missing server-supplied report choice") }
        if case .cancelReport(let actualRef) = actions.last { XCTAssertEqual(actualRef, ref) }
        else { XCTFail("Popup dismissal must cancel the active report") }
        XCTAssertNil(model.sponsoredDialog); XCTAssertFalse(model.sponsoredBusy)
        XCTAssertTrue(coordinator.retainedRuntimeDrafts.isEmpty)
    }
    func testWebsiteModeRequiresExplicitOpenAndPreservesCurrentRequestGuards() async throws {
        let model = TelegramConversationModel(id: id), fake = ConversationUIFake(), pane = UUID(), coordinator = PopupCoordinator()
        let host = FoldersUIHost(Color.clear.popupHost(coordinator), width: 800, height: 650)
        defer { host.close(); coordinator.terminate() }
        model.receive(snapshot()); model.provider = fake; model.panes.insert(pane)
        let ad = model.snapshot.sponsored.messages[0]
        model.sponsoredInfo(ad, pane: pane, why: true)
        let first = try XCTUnwrap(model.sponsoredDialog)
        let firstPage = try XCTUnwrap(TelegramSponsoredPopup.makePage(model: model, dialog: first, pane: pane, coordinator: coordinator))
        coordinator.presentNative(firstPage)
        try await assertPopupInventoryPresentation(in: host.window, root: host.view, coordinator: coordinator,
            title: "Sponsored message")
        let firstView = TelegramSponsoredPopup(model: model, dialogID: first.id, pane: pane, openChat: { _ in },
            dismiss: { coordinator.dismiss(firstPage, reason: $0) })
        firstView.chooseWebsite()
        let website = try XCTUnwrap(model.sponsoredDialog)
        let beforeOpen = await fake.sponsoredActions
        XCTAssertTrue(beforeOpen.isEmpty, "Choosing Website only presents the supplied URL")
        XCTAssertEqual(website.text, ad.url)
        coordinator.dismiss(firstPage, reason: .applied)
        XCTAssertEqual(model.sponsoredDialog?.id, website.id, "Removing an old page must preserve the replacement")
        XCTAssertNil(TelegramSponsoredPopup.makePage(model: model, dialog: website, pane: UUID(), coordinator: coordinator))
        let page = try XCTUnwrap(TelegramSponsoredPopup.makePage(model: model, dialog: website, pane: pane, coordinator: coordinator))
        coordinator.presentNative(page)
        try await assertPopupInventoryPresentation(in: host.window, root: host.view, coordinator: coordinator,
            title: "Sponsored message")
        let content = TelegramSponsoredPopup(model: model, dialogID: website.id, pane: pane, openChat: { _ in },
            dismiss: { coordinator.dismiss(page, reason: $0) })
        firstView.openWebsite()
        model.panes.remove(pane); content.openWebsite()
        let staleActions = await fake.sponsoredActions
        XCTAssertTrue(staleActions.isEmpty)
        XCTAssertTrue(coordinator.isPresented)
        model.panes.insert(pane); content.openWebsite()
        for _ in 0..<100 { if await fake.sponsoredActions.count == 1 { break }; await Task.yield() }
        let actions = await fake.sponsoredActions
        XCTAssertEqual(actions.count, 1)
        if case .click(let ref, let target, let confirmed) = actions.first {
            XCTAssertEqual(ref, ad.ref); XCTAssertEqual(target, .button); XCTAssertTrue(confirmed)
        } else { XCTFail("The explicit button must confirm the exact sponsored target") }
        XCTAssertNil(model.sponsoredDialog); XCTAssertFalse(coordinator.isPresented)
        model.receive(.init(destination: id, epoch: UUID()))
        model.sponsoredDialog = website
        XCTAssertNil(TelegramSponsoredPopup.makePage(model: model, dialog: website, pane: pane, coordinator: coordinator))
        coordinator.terminate()
    }
    func testVideoWebsiteConfirmationBelongsToItsMediaWindowAndEndsOnClose() async throws {
        _ = NSApplication.shared
        let root = try await fixtureMedia(), lease = UUID()
        let controller = TelegramSponsoredVideoWindow(), model = TelegramConversationModel(id: id), pane = UUID()
        let fake = ConversationUIFake(), movie = root.appendingPathComponent("video.mp4")
        defer { controller.close(); TelegramSponsoredRenderCache.shared.release(lease); try? FileManager.default.removeItem(at: root) }
        var value = snapshot()
        value.sponsored.messages[0].media = [.init(id: 1, kind: .video, role: .content, width: 24, height: 24, size: 1024, url: movie)]
        model.receive(value); model.provider = fake; model.panes.insert(pane)
        let ad = model.snapshot.sponsored.messages[0], url = URL(string: ad.url)!
        TelegramSponsoredRenderCache.shared.retain(lease, media: ad.media)
        for _ in 0..<200 {
            if TelegramSponsoredRenderCache.shared.assets[movie] != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(TelegramSponsoredRenderCache.shared.assets[movie])
        controller.show(ad, model: model, pane: pane, openChat: { _ in })
        for _ in 0..<100 { if controller.popups.window != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        let window = try XCTUnwrap(controller.popups.window)
        let rootView = try XCTUnwrap(window.contentView)
        XCTAssertFalse(controller.confirm(url, ref: ad.ref, model: model, pane: UUID(), target: .fullscreenButton, openChat: { _ in }))
        XCTAssertTrue(controller.confirm(url, ref: ad.ref, model: model, pane: pane, target: .fullscreenButton, openChat: { _ in }))
        try await assertPopupInventoryPresentation(in: window, root: rootView, coordinator: controller.popups,
            title: "Sponsored message")
        XCTAssertTrue(controller.popupCoordinator(for: window) === controller.popups)
        XCTAssertNil(controller.popupCoordinator(for: nil))
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(controller.popups.page?.title, "Sponsored message")
        XCTAssertTrue(NavigationPresentationGate.obscures(window))
        controller.popups.dismiss(reason: .dismiss)
        let actions = await fake.sponsoredActions
        XCTAssertTrue(actions.isEmpty)
        XCTAssertNil(controller.popupCoordinator(for: window))
        XCTAssertTrue(controller.confirm(url, ref: ad.ref, model: model, pane: pane, target: .fullscreenButton, openChat: { _ in }))
        controller.close(pane: pane)
        XCTAssertFalse(controller.popups.isPresented)
        XCTAssertFalse(NavigationPresentationGate.obscures(window))
        XCTAssertFalse(controller.confirm(url, ref: ad.ref, model: model, pane: pane, target: .fullscreenButton, openChat: { _ in }))
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
