import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import AgentPadKit

@MainActor
final class LocalAgentAvatarTests: XCTestCase {
    private var root: URL!
    private var teamScope: TeamServiceTestScope!
    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("local-avatar-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { teamScope.close(); teamScope = nil; try FileManager.default.removeItem(at: root) }

    private func picture(width: Int = 80, height: Int = 40, jpeg: Bool = false, orientation: Int = 1) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let data = NSMutableData()
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(data, (jpeg ? UTType.jpeg : .png).identifier as CFString, 1, nil))
        let metadata: [CFString: Any] = [kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "PRIVATE ORIGINAL"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.0, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "PRIVATE ORIGINAL"]]
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer)); return data as Data
    }

    func testJPGAndPNGApplyOrientationAndStripMetadataIntoSquareSRGB() throws {
        for jpeg in [false, true] {
            let input = try picture(jpeg: jpeg, orientation: 6)
            let image = try LocalAvatarImage.decode(input)
            XCTAssertEqual(image.width, 40); XCTAssertEqual(image.height, 80)
            let output = try LocalAvatarImage.png(image, crop: .init(x: 0, y: 1, zoom: 2))
            XCTAssertLessThanOrEqual(output.count, LocalAvatarImage.outputLimit)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
            let info = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(info[kCGImagePropertyPixelWidth] as? Int, 512)
            XCTAssertEqual(info[kCGImagePropertyPixelHeight] as? Int, 512)
            XCTAssertNil(info[kCGImagePropertyExifDictionary]); XCTAssertNil(info[kCGImagePropertyGPSDictionary])
            XCTAssertNil(info[kCGImagePropertyTIFFDictionary]); XCTAssertNil(info[kCGImagePropertyOrientation])
            XCTAssertNil(output.range(of: Data("PRIVATE ORIGINAL".utf8)))
        }
    }

    func testBoundsFormatsAnimationAndCorruptFilesAreRejectedBeforeFullDecode() throws {
        XCTAssertThrowsError(try LocalAvatarImage.decode(Data(repeating: 0, count: LocalAvatarImage.byteLimit + 1)))
        XCTAssertThrowsError(try LocalAvatarImage.decode(Data("not an image".utf8)))
        XCTAssertThrowsError(try LocalAvatarImage.decode(picture(width: 10_001, height: 1)))
        var png = try picture()
        // A minimal animation-control chunk: the parser rejects it before decoding.
        png.insert(contentsOf: [0, 0, 0, 8, 97, 99, 84, 76, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0], at: 33)
        XCTAssertThrowsError(try LocalAvatarImage.decode(png))
        XCTAssertThrowsError(try LocalAvatarImage.read(root))
        XCTAssertThrowsError(try LocalAvatarImage.read(URL(string: "https://example.invalid/photo.png")!))
        let rect = AvatarCrop(x: -.infinity, y: 200, zoom: -2).rect(width: 80, height: 40)
        XCTAssertEqual(rect, CGRect(x: 20, y: 0, width: 40, height: 40))
    }

    func testAtomicSaveFailureRemoveAndCASKeepTheConfirmedImage() throws {
        let probe = ProfileArchiveWriteProbe()
        let details = AgentProfileDetailsStore(fileURL: root.appendingPathComponent("agent-profile-details.json"), write: { try probe.write($0, to: $1) })
        let id = UUID(), image = try picture()
        try details.saveAvatar(image, for: id, expectedRevision: 0)
        let old = try XCTUnwrap(details.avatarURL(id)), oldBytes = try Data(contentsOf: old)
        probe.fail = true
        XCTAssertThrowsError(try details.saveAvatar(try picture(jpeg: false), for: id, expectedRevision: 1))
        XCTAssertEqual(details.avatarURL(id), old); XCTAssertEqual(try Data(contentsOf: old), oldBytes)
        XCTAssertThrowsError(try details.saveAvatar(nil, for: id, expectedRevision: 1))
        XCTAssertEqual(details.avatar(id).revision, 1)
        probe.fail = false
        XCTAssertThrowsError(try details.saveAvatar(nil, for: id, expectedRevision: 0))
        try details.saveAvatar(nil, for: id, expectedRevision: 1)
        XCTAssertEqual(details.avatar(id).revision, 2); XCTAssertNil(details.avatarURL(id)); XCTAssertNil(details.image(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(AgentProfileDetailsStore(fileURL: details.fileURL).avatar(id), details.avatar(id))
    }

    func testEditorCancelSaveDuplicateSaveRemoveAndConcurrentEdit() async throws {
        let profiles = AgentProfileStore(fileURL: root.appendingPathComponent("agent-profiles.json"))
        let profile = try profiles.add(template: .codex, folder: root, name: "Builder")
        let input = root.appendingPathComponent("photo.jpg"); try picture(jpeg: true).write(to: input)
        let editor = AgentProfileEditor(profile: profile, profiles: profiles)
        await editor.choose(input); XCTAssertNotNil(editor.source)
        editor.cancelCrop(); XCTAssertNil(editor.source); XCTAssertNil(profiles.details.avatarURL(profile.id))
        await editor.choose(input)
        let save = Task { await editor.saveCrop() }
        await Task.yield(); await editor.saveCrop(); await save.value
        XCTAssertEqual(profiles.details.avatar(profile.id).revision, 1)
        let stale = AgentProfileEditor(profile: profile, profiles: profiles)
        await editor.remove()
        await stale.choose(input); await stale.saveCrop()
        guard case .failed(_, recovery: .reload) = stale.operation else { return XCTFail("Stale editor must reload") }
        XCTAssertNil(profiles.details.avatarURL(profile.id))
        stale.reload(); XCTAssertNil(stale.source)
        editor.name = "Renamed"; editor.saveName()
        XCTAssertEqual(profiles.profile(profile.id)?.name, "Renamed")
        XCTAssertEqual(profiles.profile(profile.id)?.templateID, "codex")
        XCTAssertEqual(profiles.profile(profile.id)?.folder, canonicalDiskPath(root))
    }

    func testUnreadableSidecarIsNeverReplaced() throws {
        let file = root.appendingPathComponent("agent-profile-details.json"), bytes = Data("broken".utf8)
        try bytes.write(to: file)
        let store = AgentProfileDetailsStore(fileURL: file)
        XCTAssertThrowsError(try store.saveAvatar(nil, for: UUID(), expectedRevision: 0))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testStartupAndRemoveSweepAvatarsLeftByInterruptedSave() throws {
        let file = root.appendingPathComponent("agent-profile-details.json")
        let details = AgentProfileDetailsStore(fileURL: file), id = UUID(), other = UUID()
        let pixels = try picture()
        try details.saveAvatar(pixels, for: id, expectedRevision: 0)
        let old = try XCTUnwrap(details.avatarURL(id))
        try details.saveAvatar(pixels, for: other, expectedRevision: 0)
        let retained = try XCTUnwrap(details.avatarURL(other))
        try details.saveAvatar(pixels, for: id, expectedRevision: 1)
        let current = try XCTUnwrap(details.avatarURL(id))
        // The reference committed, but the process died before deleting A.
        try pixels.write(to: old)
        let restarted = AgentProfileDetailsStore(fileURL: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        // Also cover a file written before its reference could commit.
        let orphan = root.appendingPathComponent("profile-assets/\(UUID())/\(UUID()).png")
        try AgentProfileDetailsStore.writePrivate(pixels, orphan)
        try restarted.saveAvatar(nil, for: id, expectedRevision: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
    }

    func testFailedAvatarDeletionIsReportedAndRetriedByNextSave() throws {
        let details = AgentProfileDetailsStore(fileURL: root.appendingPathComponent("agent-profile-details.json"))
        let id = UUID(), pixels = try picture()
        try details.saveAvatar(pixels, for: id, expectedRevision: 0)
        let old = try XCTUnwrap(details.avatarURL(id)), directory = old.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        try details.saveAvatar(nil, for: id, expectedRevision: 1)
        XCTAssertNil(details.avatarURL(id), "The removal reference commits before cleanup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertNotNil(details.problem, "Cleanup failure must remain visible until retried")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try details.saveAvatar(pixels, for: UUID(), expectedRevision: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertNil(details.problem)
    }

    func testStartupSweepPreservesFilesWhenReferencesAreUnreadable() throws {
        let file = root.appendingPathComponent("agent-profile-details.json")
        let orphan = root.appendingPathComponent("profile-assets/\(UUID())/\(UUID()).png")
        try AgentProfileDetailsStore.writePrivate(picture(), orphan)
        try Data("broken".utf8).write(to: file)
        let unreadable = AgentProfileDetailsStore(fileURL: file)
        XCTAssertNotNil(unreadable.problem)
        XCTAssertThrowsError(try unreadable.saveAvatar(nil, for: UUID(), expectedRevision: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path), "Unknown references must not be treated as empty")
        try FileManager.default.removeItem(at: file)
        let empty = AgentProfileDetailsStore(fileURL: file)
        XCTAssertNil(empty.problem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "A crash before the first reference commit is recoverable")
    }

    func testProfileAndCropRenderInBothThemes() async throws {
        let profiles = AgentProfileStore(fileURL: root.appendingPathComponent("agent-profiles.json"))
        let profile = try profiles.add(template: .codex, folder: root, name: "Writer")
        let editor = AgentProfileEditor(profile: profile, profiles: profiles)
        let input = root.appendingPathComponent("photo.png"); try picture().write(to: input)
        let previous = AgentPadSettingsModel.testModel
        defer { AgentPadSettingsModel.testModel = previous }
        for crop in [false, true] {
            if crop { await editor.choose(input) }
            for dark in [false, true] {
                AgentPadSettingsModel.testModel = AgentPadSettingsModel(read: { ["appearance": ["mode": dark ? "dark" : "light"]] }, write: { _ in }, appliesRuntimeEffects: false)
                let host = NSHostingView(rootView: AgentProfileEditorView(state: TabState(route: .agentProfile(profile.id)), editor: editor))
                host.frame = NSRect(x: 0, y: 0, width: 820, height: 660); host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let path = ProcessInfo.processInfo.environment["AGENTPAD_TEST_ARTIFACTS"] {
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("profile-\(crop ? "crop" : "editor")-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
    func testInterruptedPublicationMappingRetriesTheSameUUIDAfterSidecarWriteFailure() throws {
        let probe = ProfileArchiveWriteProbe(); probe.fail = true
        let details = AgentProfileDetailsStore(fileURL: root.appendingPathComponent("agent-profile-details.json"), write: { try probe.write($0, to: $1) })
        let profiles = AgentProfileStore(fileURL: root.appendingPathComponent("agent-profiles.json"), details: details)
        let agent = TeamPublishedAgent(name: "builder", description: "", folder: root.path)
        XCTAssertThrowsError(try profiles.mapPublications([agent]))
        let id = try XCTUnwrap(profiles.profiles.first?.id)
        probe.fail = false
        try profiles.mapPublications([agent])
        XCTAssertEqual(profiles.profiles.map(\.id), [id])
        XCTAssertEqual(details.archive.publications[agent.id.uuidString], id)
    }

    func testClosedEditorRejectsQueuedOperationsAndLateDecode() async throws {
        let profiles = AgentProfileStore(fileURL: root.appendingPathComponent("agent-profiles.json"))
        let profile = try profiles.add(template: .codex, folder: root)
        let input = root.appendingPathComponent("photo.png"); try picture().write(to: input)
        let editor = AgentProfileEditor(profile: profile, profiles: profiles)
        let read = Task { await editor.choose(input) }
        await Task.yield(); editor.invalidate(); await read.value
        await editor.remove(); await editor.retry(); await editor.choose(input); await editor.saveCrop()
        editor.name = "Late rename"; editor.saveName()
        XCTAssertNil(editor.source); XCTAssertEqual(profiles.details.avatar(profile.id).revision, 0)
        XCTAssertEqual(profiles.profile(profile.id), profile)
    }

}
