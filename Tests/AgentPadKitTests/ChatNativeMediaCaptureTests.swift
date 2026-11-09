import AppKit
import AgentPadQuietTestSupport
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

/// The shared ContactAvatar remains the reference for the native avatar.
/// Historical complete message-row media pairs are archived outside the build.
@MainActor final class ChatNativeMediaCaptureTests: XCTestCase {
    private typealias S = NativeTimelineSnapshot

    func testW06AvatarVariantsAgainstActualLegacyThreeCheckGate() async throws {
        let run = try W06CaptureRun()
        defer { run.close() }
        let key = ChatOrgKey(server: try ChatServerAddress(parsing: "https://w06-avatars.example"),
            accountId: "01900000-0000-7000-8000-000000000003", orgId: "01900000-0000-7000-8000-000000000005")
        let service = ChatService(files: ChatFiles(directory: run.scratch), tokens: FakeTokenStore())
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [W06CapturePreviewProtocol.self]) }
        service.closeRemoteSession = { _, _ in }
        try service.saveSignIn(.init(server: key.server, accountId: key.accountId, sessionId: "s", deviceName: "Test", orgId: key.orgId), token: "t")
        let session = service.session(for: key), store = try XCTUnwrap(service.session(for: key).store)
        try store.setGeneration("g")
        try store.apply(.init(cursors: [:], members: [.init(accountId: key.accountId, handle: "me", name: "Me", role: "member")]), confirmsRights: "s")
        session.snapshotOwed = false
        service.avatarGenerations[key.server] = "g"; service.serverCapabilities[key.server] = ["chat.avatars"]
        let reference = ChatAvatarReference(key: key, subject: .account(key.accountId))
        let imageID = "01900000-0000-7000-8000-000000000099"
        let conversation = S.Conversation(key: key, address: .channel("avatar-fixture"), root: nil)
        let owner = ChatNativeShellCell.Binding(id: .init(conversation: conversation, kind: .message("avatar-fixture")),
            epoch: UUID(), contentRevision: 1, reuseGeneration: 1)
        do {
            for dark in [false, true] {
                run.theme(dark: dark)
                for width in ChatNativeParityCaptureWidths.standard {
                    for size: CGFloat in [32, 21] {
                        for state in ["person-fallback", "agent-fallback", "unicode-fallback", "pending", "remote-image", "held-image", "revoked-image", "transparent-image"] {
                            service.invalidateAvatars(); session.snapshotOwed = false
                            service.avatars.countLimit = state == "held-image" ? 0 : 96
                            let context = try XCTUnwrap(service.avatarDisplayContext(key))
                            let wantsImage = !state.hasSuffix("fallback")
                            let metadata = ChatAvatarMetadata(revision: 1, imageId: wantsImage ? imageID : nil)
                            service.avatars.receive(metadata, for: reference, context: context)
                            let bytes = state == "transparent-image" ? try Self.transparentAvatar() : try AvatarTestImage.png()
                            W06CapturePreviewProtocol.configure(held: state == "pending", failure: false, bytes: bytes,
                                headers: ["Content-Type": "image/png", "X-Avatar-Revision": "1", "X-AgentPad-Generation": "g"])
                            if ["remote-image", "revoked-image", "transparent-image"].contains(state) {
                                let loaded = await service.avatars.load(reference)
                                XCTAssertNotNil(loaded)
                            }
                            let placeholder = AvatarPlaceholder(stableID: reference.subject.id,
                                name: state == "unicode-fallback" ? "🧑🏽‍💻 e\u{301}lodie" : "Anna",
                                kind: state == "agent-fallback" ? .agent : .person)
                            let content = AnyView(VStack(spacing: 0) {
                                Color.clear.frame(height: 24)
                                ContactAvatar(stableID: placeholder.stableID, name: placeholder.name, kind: placeholder.kind,
                                    size: size, remote: reference, service: service)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24)
                                    .frame(height: size).chatParity("avatar-row", "row")
                                Spacer(minLength: 0)
                            }.frame(width: width, height: 600, alignment: .topLeading)
                                .background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground))
                            let measured = ChatTimelineParityLayout.legacy(content: content)
                            let legacy = ChatQuietHost(content: measured.content, dark: dark, width: width, height: 600)
                            let canvas = W06AvatarCanvas(frame: CGRect(x: 0, y: 0, width: width, height: 600))
                            let native = ChatQuietHost(view: canvas, dark: dark, width: width, height: 600)
                            defer { canvas.avatar.unbind(); legacy.close(); native.close(); W06CapturePreviewProtocol.release() }
                            let style = ChatTimelineAdapter.style(scale: native.window.backingScaleFactor,
                                locale: .current, calendar: .current,
                                increasedContrast: false, alwaysShowTime: false)
                            canvas.surface = style.color("surface")
                            canvas.avatar.frame = CGRect(x: 24, y: 24, width: size, height: size)
                            func configure() {
                                let source = S.Avatar(reference: reference, metadata: service.avatars.metadata[reference.subject],
                                    generation: service.avatars.imageGeneration(reference), context: service.avatarDisplayContext(key))
                                canvas.avatar.configure(placeholder: placeholder, source: source, owner: owner,
                                    style: style, service: service, fallback: .own)
                                canvas.avatar.setVisible(true)
                            }
                            configure()
                            try await legacy.settle(); try await native.settle()
                            if wantsImage && state != "pending" {
                                for _ in 0..<25 {
                                    if canvas.avatar.hasImage { break }
                                    try await legacy.settle(); try await native.settle()
                                }
                                XCTAssertTrue(canvas.avatar.hasImage, "Requested native avatar must hold actual decoded image: " + state)
                            }
                            if state == "held-image" { XCTAssertNil(service.avatars.image(reference), "Mounted views must hold the image outside the zero-entry cache") }
                            if state == "revoked-image" {
                                session.snapshotOwed = true
                                configure(); try await legacy.settle(); try await native.settle()
                                XCTAssertFalse(canvas.avatar.hasImage)
                            }
                            APQuietSelectWindow(legacy.window)
                            let current = try ChatNativeMediaParity.legacy(measured.collector, in: legacy.view)
                            let expected = try Self.bitmap(legacy.view)
                            APQuietSelectWindow(native.window)
                            let avatar = try ChatNativeMediaParity.avatar(canvas.avatar, in: canvas)
                            let candidate = try ChatTimelineParityLayout.finish([
                                .init(id: "viewport", role: "viewport", frame: canvas.bounds,
                                    colorTokens: ["background": try ChatTimelineParityLayout.color(canvas.surface, in: canvas)]),
                                .init(id: "topInset", role: "inset", frame: CGRect(x: 0, y: 0, width: width, height: 24)),
                                .init(id: "avatar-row", role: "row", frame: CGRect(x: 0, y: 24, width: width, height: size)), avatar])
                            let actual = try Self.bitmap(canvas)
                            let shown = try XCTUnwrap(current.elements.first { $0.id.hasPrefix("w06/avatar/") })
                            XCTAssertEqual(shown.text == nil, wantsImage && !["pending", "revoked-image"].contains(state), "Reference must reach the requested image/fallback branch")
                            try Self.record(id: "avatar-\(state)-\(Int(size))-\(Int(width))-\(dark ? "dark" : "light")",
                                inventory: ["R07", "R08", "S24"], current: current, candidate: candidate,
                                expected: expected, actual: actual,
                                fixture: ["stableID": placeholder.stableID, "name": placeholder.name, "size": size, "state": state], output: run.output)
                            W06CapturePreviewProtocol.release()
                        }
                    }
                }
            }
        } catch {
            await service.disconnect()
            throw error
        }
        await service.disconnect()
    }

    private static func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let result = try ChatTimelineCaptureColor.bitmap(view)
        return result
    }
    private static func transparentAvatar() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
    }
    private static func chartPixels(_ image: NSBitmapImageRep) -> Int {
        var count = 0
        for y in stride(from: 0, to: image.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: image.pixelsWide, by: 4) {
                if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.blueComponent > color.redComponent * 2,
                   color.blueComponent > color.greenComponent * 1.5 { count += 1 }
            }
        }
        return count
    }
    private static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private static func record(id: String, inventory: [String], current: ChatTimelineParityMetadata,
                               candidate: ChatTimelineParityMetadata, expected: NSBitmapImageRep,
                               actual: NSBitmapImageRep, fixture: Any, observations: [String: Any] = [:], output: URL) throws {
        let result = ChatTimelineParity.compare(currentLayout: current, candidateLayout: candidate,
            current: try .init(expected), candidate: try .init(actual))
        for (suffix, image) in [("legacy", expected), ("native", actual)] {
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(
                to: output.appendingPathComponent(id + "-" + suffix + ".png"), options: .withoutOverwriting)
        }
        let evidence: [String: Any] = ["captureID": id, "inventoryIDs": inventory,
            "legacy": try json(current), "native": try json(candidate), "result": try json(result),
            "fixture": fixture, "observations": observations, "fullAcceptance": result.passes, "cropped": false,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "locale": Locale.current.identifier,
            "timeZone": TimeZone.current.identifier, "accent": NSColor.controlAccentColor.description,
            "increaseContrast": observations["increasedContrast"] ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            "workspaceIncreaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(
            to: output.appendingPathComponent(id + ".json"), options: .withoutOverwriting)
        XCTAssertTrue(result.passes, "W06 three-check gate: " + id + ": " + (current.captureGaps + candidate.captureGaps).joined(separator: "; "))
    }
}

@MainActor private final class W06AvatarCanvas: NSView {
    let avatar = ChatNativeAvatarView(frame: .zero)
    var surface = NSColor.clear { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override init(frame: CGRect) { super.init(frame: frame); addSubview(avatar) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { surface.setFill(); bounds.fill() }
}

@MainActor private final class W06CaptureRun {
    let output: URL
    let scratch: URL
    private let scope: TeamServiceTestScope
    private let previousBadge = ChatNotifications.badgeChanged
    private let previousTheme: (AgentPadAppearanceMode, String, String, Bool)
    private let settingsURL: URL
    private let hadSettingsFile: Bool
    private let previousTime: Any?
    private let previousEnhanced: Any?

    init(captureFlag: String = "AGENTPAD_CHAT_NATIVE_W06_CAPTURE") throws {
        guard ProcessInfo.processInfo.environment[captureFlag] == "1" else {
            throw XCTSkip("Set \(captureFlag)=1 to record media pairs")
        }
        XCTAssertTrue(APQuietIsEnabled())
        ChatScrollAppKitSettings.install(); AgentPadFonts.registerOnce(); _ = NSApplication.shared
        scope = TeamServiceTestScope()
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        previousEnhanced = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["AGENTPAD_CHAT_PARITY_EVIDENCE"]))
        output = root.appendingPathComponent("w06-media-" + UUID().uuidString)
        scratch = output.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        ChatStubProtocol.reset { _, _ in .failure(URLError(.unsupportedURL)) }
        let quietRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build").standardizedFileURL
        let themes = AgentPadTerminalTheme.ghosttyUserThemesDirectory().standardizedFileURL
        guard themes.path.hasPrefix(quietRoot.path + "/quiet-xctest-") else {
            throw ChatTimelineParityLayout.failure("W06 fixture requires its own quiet sandbox theme directory")
        }
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        settingsURL = AgentPadSettings.url.standardizedFileURL
        guard settingsURL.path.hasPrefix(quietRoot.path + "/quiet-xctest-") else {
            throw ChatTimelineParityLayout.failure("W06 fixture requires its own quiet sandbox settings file")
        }
        hadSettingsFile = FileManager.default.fileExists(atPath: settingsURL.path)
        if !hadSettingsFile {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: settingsURL, options: .withoutOverwriting)
        }
        ChatNotifications.badgeChanged = {}
        let settings = AgentPadSettingsModel.shared
        previousTheme = (settings.appearanceMode, settings.lightTerminalThemeSelection,
            settings.darkTerminalThemeSelection, settings.pairedThemeSchemaEnabled)
        settings.prepareFirstLaunchAppearance()
        settings.lightTerminalThemeSelection = AgentPadSettingsModel.defaultLightThemeSelection
        settings.darkTerminalThemeSelection = AgentPadSettingsModel.defaultDarkThemeSelection
        previousTime = UserDefaults.standard.object(forKey: "chat.ux2.alwaysShowTime")
        UserDefaults.standard.set(false, forKey: "chat.ux2.alwaysShowTime")
    }
    func theme(dark: Bool) { AgentPadSettingsModel.shared.appearanceMode = dark ? .dark : .light }
    func finish(expected: Int) throws {
        let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
        let pairs = files.filter { $0.pathExtension == "json" }.map(\.lastPathComponent).sorted()
        XCTAssertEqual(pairs.count, expected)
        XCTAssertEqual(files.filter { $0.pathExtension == "png" }.count, expected * 2)
        try JSONSerialization.data(withJSONObject: ["expectedPairs": expected, "recordedPairs": pairs.count, "pairs": pairs],
            options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("pairs.json"), options: .withoutOverwriting)
    }
    func close() {
        W06CapturePreviewProtocol.release(); ChatStubProtocol.reset(); scope.close()
        ChatNotifications.badgeChanged = previousBadge
        NSApp.accessibilitySetValue(previousEnhanced, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let settings = AgentPadSettingsModel.shared
        if !previousTheme.3 { settings.load() }
        settings.appearanceMode = previousTheme.0
        settings.lightTerminalThemeSelection = previousTheme.1
        settings.darkTerminalThemeSelection = previousTheme.2
        if !hadSettingsFile { try? FileManager.default.removeItem(at: settingsURL) }
        if let previousTime { UserDefaults.standard.set(previousTime, forKey: "chat.ux2.alwaysShowTime") }
        else { UserDefaults.standard.removeObject(forKey: "chat.ux2.alwaysShowTime") }
        try? FileManager.default.removeItem(at: scratch)
    }
}
