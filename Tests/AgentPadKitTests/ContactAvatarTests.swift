import XCTest
import SwiftUI
import GRDB
@testable import AgentPadKit

final class ContactAvatarTests: XCTestCase {
    @MainActor
    func testRepeatedRendersAuthorizeEachReferenceOnlyOncePerEpoch() async throws {
        let fixture = try AvatarTestFixture()
        let service = fixture.service, cache = service.avatars
        let denied = ChatAvatarReference(key: fixture.key, subject: .account(ChatUUID.v7()))
        let refs = [fixture.own, denied]
        let reads = Counter()
        var transports = 0
        service.makeAPI = {
            transports += 1
            return ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self])
        }
        try await fixture.store.queue.write { db in
            db.trace { event in
                if Thread.isMainThread, case .statement(let statement) = event,
                   statement.sql.uppercased().hasPrefix("SELECT") { reads.increment() }
            }
        }
        func row(_ name: String) -> some View {
            HStack {
                ForEach(0..<4) { index in
                    let ref = refs[index % refs.count]
                    ContactAvatar(stableID: ref.subject.id, name: name, kind: .person, remote: ref, service: service)
                }
            }
        }
        let host = NSHostingView(rootView: row("Initial"))
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        for epoch in 0..<2 {
            if epoch > 0 { service.invalidateAvatars() }
            let context = try XCTUnwrap(service.avatarDisplayContext(fixture.key))
            cache.receive(.init(revision: 1, imageId: nil), for: fixture.own, context: context)
            let before = reads.value, apiCount = transports
            // Even the first body of a new epoch cannot query or make a transport.
            _ = ContactAvatar(stableID: "cold", name: "Cold", kind: .person, remote: fixture.own, service: service).body
            XCTAssertEqual(reads.value, before)
            XCTAssertEqual(transports, apiCount)
            for render in 0..<20 {
                host.rootView = row("Epoch \(epoch), render \(render)")
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(reads.value, (epoch + 1) * refs.count, "One authorization DB read per reference and epoch, including denials")
            XCTAssertEqual(transports, epoch + 1, "Only loading tasks create the shared transport")
        }
        await fixture.close()
    }

    @MainActor
    func testHeldAvatarIsRemovedWhenTeamStreamIsUnsubscribed() async throws {
        try await checkHeldAvatarAfterAccessChange(unsubscribe: true)
    }

    @MainActor
    func testHeldAvatarRechecksAuthorizationAfterMembershipChanges() async throws {
        try await checkHeldAvatarAfterAccessChange(unsubscribe: false)
    }

    @MainActor
    private func checkHeldAvatarAfterAccessChange(unsubscribe: Bool) async throws {
        let fixture = try AvatarTestFixture()
        let team = ChatUUID.v7(), owner = ChatUUID.v7()
        let ref = ChatAvatarReference(key: fixture.key, subject: .agent(ChatUUID.v7()))
        let stream = "org:\(fixture.key.orgId)"
        try fixture.store.apply(.init(cursors: [stream: 0, "team:\(team)": 0], members: [
            .init(accountId: fixture.key.accountId, handle: "me", name: "Me", role: "member"),
            .init(accountId: owner, handle: "owner", name: "Owner", role: "member")
        ], teams: [.init(teamId: team, name: "Team")], teamMembers: [.init(teamId: team, accountId: fixture.key.accountId)],
            agents: [.init(agentId: ref.subject.id, ownerAccountId: owner, name: "Agent", description: "", access: "read-git",
                enabled: true, executorSessionId: nil, executorDeviceName: nil, available: true, teamIds: [team])]), confirmsRights: "s")
        let service = fixture.service, cache = service.avatars
        cache.countLimit = 0 // Only the mounted view can retain these bytes.
        let context = try XCTUnwrap(service.avatarAuthorization(ref)?.context)
        cache.receive(.init(revision: 1, imageId: ChatUUID.v7()), for: ref, context: context)
        let bytes = try AvatarTestImage.png()
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, headers: ["Content-Type": "image/png", "X-Avatar-Revision": "1", "X-AgentPad-Generation": "g"], body: bytes)) }
        func row(_ name: String) -> some View {
            HStack(spacing: 0) {
                ContactAvatar(stableID: ref.subject.id, name: name, kind: .agent, size: 64, remote: ref, service: service)
                ContactAvatar(stableID: ref.subject.id, name: name, kind: .agent, size: 64)
            }
        }
        let host = NSHostingView(rootView: row("Agent"))
        host.frame = NSRect(x: 0, y: 0, width: 128, height: 64)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func matchesPlaceholder() throws -> Bool {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let shown = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 4, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            let placeholder = try XCTUnwrap(bitmap.colorAt(x: 3 * bitmap.pixelsWide / 4, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            return abs(shown.redComponent - placeholder.redComponent) < 0.02 &&
                abs(shown.greenComponent - placeholder.greenComponent) < 0.02 &&
                abs(shown.blueComponent - placeholder.blueComponent) < 0.02
        }
        let loaded = ContinuousClock.now + .seconds(3)
        while try matchesPlaceholder(), ContinuousClock.now < loaded { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(try matchesPlaceholder(), "The view must first hold the downloaded photo")
        XCTAssertNil(cache.image(ref), "The photo is held by the view, outside the shared cache")
        let epoch = service.avatarEpoch
        if unsubscribe {
            let socket = ChatSocket(server: fixture.key.server, token: "t")
            let sync = ChatSync(key: fixture.key, store: fixture.store, api: service.makeAPI(fixture.key.server),
                                socket: socket, outbox: nil, token: "t")
            sync.onAvatarAccessChanged = { service.invalidateAvatars() }
            sync.dropped("team:\(team)")
            XCTAssertGreaterThan(service.avatarEpoch, epoch, "Unsubscribing must wake mounted avatars even without a row update")
            sync.stop()
        } else {
            XCTAssertEqual(try fixture.store.apply(CallJSON.event(stream, 1, "member.remove", ["account_id": owner])), .applied)
            XCTAssertGreaterThan(service.avatarEpoch, epoch, "Membership commits must invalidate held photos without another row update")
        }
        XCTAssertNotNil(service.avatarContext(fixture.key), "The organization remains authorized")
        XCTAssertNil(service.avatarAuthorization(ref), "Only this avatar's visibility was revoked")
        let revoked = ContinuousClock.now + .seconds(2)
        while try !matchesPlaceholder(), ContinuousClock.now < revoked { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(try matchesPlaceholder(), "An unauthorized held photo must become the placeholder")
        XCTAssertEqual(ChatStubProtocol.seen.count, 1, "Revocation must not fetch the now-inaccessible avatar")
        await fixture.close()
    }

    @MainActor
    func testMountedAvatarsStayVisibleWhenImagesExceedCacheLimit() async throws {
        let fixture = try AvatarTestFixture()
        let refs = (0..<3).map { _ in ChatAvatarReference(key: fixture.key, subject: .account(ChatUUID.v7())) }
        try fixture.store.apply(.init(cursors: [:], members: refs.map {
            .init(accountId: $0.subject.id, handle: $0.subject.id, name: "Photo", role: "member")
        }), confirmsRights: "s")
        let cache = fixture.service.avatars
        cache.countLimit = 1
        let context = try XCTUnwrap(fixture.service.avatarContext(fixture.key))
        for ref in refs { cache.receive(.init(revision: 1, imageId: ChatUUID.v7()), for: ref, context: context) }
        let bytes = try AvatarTestImage.png()
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, headers: ["Content-Type": "image/png", "X-Avatar-Revision": "1", "X-AgentPad-Generation": "g"], body: bytes)) }
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            ForEach(refs, id: \.self) { ref in
                ContactAvatar(stableID: ref.subject.id, name: "X", kind: .person, size: 64, remote: ref, service: fixture.service)
            }
            ContactAvatar(stableID: "reference", name: "X", kind: .person, size: 64, image: NSImage(data: bytes))
        })
        host.frame = NSRect(x: 0, y: 0, width: 256, height: 64)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(3)
        while ChatStubProtocol.seen.count < refs.count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let expected = try XCTUnwrap(bitmap.colorAt(x: 7 * bitmap.pixelsWide / 8, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        for index in refs.indices {
            let pixel = try XCTUnwrap(bitmap.colorAt(x: (2 * index + 1) * bitmap.pixelsWide / 8,
                y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            XCTAssertEqual(pixel.redComponent, expected.redComponent, accuracy: 0.02, "Every mounted view must keep its photo")
            XCTAssertEqual(pixel.greenComponent, expected.greenComponent, accuracy: 0.02)
            XCTAssertEqual(pixel.blueComponent, expected.blueComponent, accuracy: 0.02)
        }
        XCTAssertLessThanOrEqual(refs.filter { cache.image($0) != nil }.count, 1, "The shared cache stays bounded")
        XCTAssertEqual(ChatStubProtocol.seen.count, refs.count, "Visible photos must not evict and reload each other in a loop")
        let versions = cache.metadata
        cache.clear()
        for ref in refs { cache.receive(versions[ref.subject], for: ref, context: context) }
        let reloadDeadline = ContinuousClock.now + .seconds(2)
        while ChatStubProtocol.seen.count < 2 * refs.count, ContinuousClock.now < reloadDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(ChatStubProtocol.seen.count, 2 * refs.count, "A cache invalidation reloads even when server metadata stays identical")
        await fixture.close()
    }

    @MainActor
    func testTransparentAvatarReplacesThePlaceholder() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8,
            bytesPerRow: 40, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: 10, height: 10))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 10))
        let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: NSSize(width: 10, height: 10))
        let host = NSHostingView(rootView: ContactAvatar(stableID: "local", name: "Agent", kind: .agent,
            size: 100, image: image).background(Color.black))
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(center.redComponent, 0.02)
        XCTAssertLessThan(center.greenComponent, 0.02)
        XCTAssertLessThan(center.blueComponent, 0.02)
        let opaque = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 10, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(opaque.redComponent, 0.98)
        XCTAssertGreaterThan(opaque.greenComponent, 0.98)
        XCTAssertGreaterThan(opaque.blueComponent, 0.98)
    }

    func testFixedUTF8HashesAndSameNameDifferentIdentity() {
        XCTAssertEqual(AvatarPlaceholder.hash(""), 0x811c9dc5)
        XCTAssertEqual(AvatarPlaceholder.hash("hello"), 0x4f9f2cab)
        XCTAssertEqual(AvatarPlaceholder.hash("агент-é"), 0x864a7282)
        var alex = AvatarPlaceholder(stableID: "acc_01J7VQ3A9KA0", name: "Alex Kim", kind: .person)
        let otherAlex = AvatarPlaceholder(stableID: "acc_01J9C0F4T8AT", name: alex.name, kind: .person)
        XCTAssertEqual(alex.colorIndex, 7)
        XCTAssertEqual(otherAlex.colorIndex, 1)
        let original = alex.color(isLight: true)
        alex.name = "Sam Lee"
        XCTAssertEqual(alex.letter, "S")
        XCTAssertEqual(alex.color(isLight: true), original)
    }

    func testOneUnicodeLetterOrNumberSkippingEmojiAndWhitespace() {
        for (name, letter) in [("  élodie Martin", "É"), ("e\u{301}lodie", "É"), ("🐇 Rabbit", "R"),
                               (" Марина Иванова ", "М"), ("deploy-bot", "D"), ("--42 bots", "4"),
                               ("李 明", "李"), ("🤖💬  ", "?"), ("", "?")] {
            XCTAssertEqual(AvatarPlaceholder.letter(name), letter, name)
        }
    }

    func testPaletteContrastInBothThemes() {
        func channel(_ value: UInt32) -> Double {
            let s = Double(value) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        for palette in [AvatarPlaceholder.lightPalette, AvatarPlaceholder.darkPalette] {
            XCTAssertEqual(palette.count, 12)
            XCTAssertEqual(Set(palette).count, 12)
            for rgb in palette {
                let luminance = 0.2126 * channel((rgb >> 16) & 255)
                    + 0.7152 * channel((rgb >> 8) & 255) + 0.0722 * channel(rgb & 255)
                XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 4.5, String(rgb, radix: 16))
            }
        }
    }

    func testAttributionUsesStableAgentOrAccountNeverSessionName() {
        let agent = ChatAuthorIdentity(account: "owner", agent: "agent-id", session: "Old name")
        let renamed = ChatAuthorIdentity(account: "owner", agent: "agent-id", session: "New name")
        XCTAssertEqual(agent.avatarID, "agent-id")
        XCTAssertEqual(agent.avatarID, renamed.avatarID)
        let legacy = ChatAuthorIdentity(account: "account-id", agent: nil, session: "Terminal")
        XCTAssertEqual(legacy.avatarID, "account-id")
        XCTAssertTrue(legacy.isBot)
        let person = AvatarPlaceholder(stableID: "account-id", name: "Alex", kind: .person)
        let bot = AvatarPlaceholder(stableID: "agent-id", name: "reviewer", kind: .agent)
        XCTAssertEqual(person.cornerRadius(size: 100), 50)
        XCTAssertEqual(bot.cornerRadius(size: 100), 27)
    }
}
