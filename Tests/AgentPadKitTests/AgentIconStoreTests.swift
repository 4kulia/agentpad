import AppKit
import XCTest
@testable import AgentPadKit

@MainActor
final class AgentIconStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpad-icon-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        AgentIconStore.directoryOverride = tempDir
        // `AgentIcon.cache` is process-wide and keyed on filename alone, so
        // without this a cached image outlives the temp directory it came from
        // and bleeds into the next test.
        AgentIcon.invalidateCache()
    }

    override func tearDown() async throws {
        AgentIconStore.directoryOverride = nil
        AgentIcon.invalidateCache()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    // MARK: - normalizedPNG

    func testDownscalesOversizedSourceToMaxDimension() throws {
        let png = try XCTUnwrap(AgentIconStore.normalizedPNG(from: bitmap(width: 2000, height: 2000)))
        let (w, h) = try pixelSize(of: png)
        XCTAssertEqual(w, Int(AgentIconStore.maxDimension))
        XCTAssertEqual(h, Int(AgentIconStore.maxDimension))
    }

    func testKeepsSmallSourceAtItsOwnResolution() throws {
        let png = try XCTUnwrap(AgentIconStore.normalizedPNG(from: bitmap(width: 64, height: 64)))
        let (w, h) = try pixelSize(of: png)
        XCTAssertEqual(w, 64, "a source under the cap must not be upscaled")
        XCTAssertEqual(h, 64)
    }

    func testPreservesAspectRatioOfWideSource() throws {
        let cap = Int(AgentIconStore.maxDimension)
        let png = try XCTUnwrap(AgentIconStore.normalizedPNG(from: bitmap(width: 2000, height: 500)))
        let (w, h) = try pixelSize(of: png)
        XCTAssertEqual(w, cap, "the long edge lands on the cap")
        XCTAssertEqual(h, cap / 4, "the short edge follows the 4:1 aspect")
    }

    func testPreservesAspectRatioOfTallSource() throws {
        let cap = Int(AgentIconStore.maxDimension)
        let png = try XCTUnwrap(AgentIconStore.normalizedPNG(from: bitmap(width: 500, height: 2000)))
        let (w, h) = try pixelSize(of: png)
        XCTAssertEqual(w, cap / 4)
        XCTAssertEqual(h, cap)
    }

    /// A vector source has no pixel representation — its `size` is an
    /// artboard in points, so honouring it would bake a 24pt SVG down to a
    /// blurry 24px file.
    ///
    /// Uses a real vector rep, not a bare `NSImage`: a repless image draws
    /// nothing, so the dimension assertions below would pass on a fully
    /// transparent output. The opacity check is what makes this a test of the
    /// vector path rather than of `NSBitmapImageRep`'s allocator.
    func testRasterizesVectorSourceAtMaxDimensionAndActuallyDrawsIt() throws {
        let svg = tempSource(ext: "svg")
        try Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">
        <rect x="0" y="0" width="24" height="24" fill="#FF0000"/></svg>
        """.utf8).write(to: svg)
        let image = try XCTUnwrap(NSImage(contentsOf: svg), "AppKit no longer decodes SVG")
        XCTAssertFalse(
            image.representations.contains { $0 is NSBitmapImageRep },
            "a vector source must have no bitmap rep, or it takes the raster branch"
        )
        let png = try XCTUnwrap(AgentIconStore.normalizedPNG(from: image))
        let (w, h) = try pixelSize(of: png)
        XCTAssertEqual(w, Int(AgentIconStore.maxDimension))
        XCTAssertEqual(h, Int(AgentIconStore.maxDimension))
        XCTAssertGreaterThan(try opaqueFraction(of: png), 0.9, "the vector must actually rasterise")
    }

    /// Aspect ratio must come from the representation's PIXELS, not
    /// `image.size` — they disagree on any file carrying non-square DPI, and
    /// honouring `size` bakes a squashed PNG that only a re-import can undo.
    func testUsesPixelAspectNotLogicalSizeForNonSquareDPI() throws {
        let image = bitmap(width: 2000, height: 500)
        // What a 2000x500 PNG with square-ish DPI metadata reports.
        image.size = NSSize(width: 500, height: 500)
        let png = try XCTUnwrap(AgentIconStore.normalizedPNG(from: image))
        let (w, h) = try pixelSize(of: png)
        XCTAssertEqual(w, Int(AgentIconStore.maxDimension))
        XCTAssertEqual(h, Int(AgentIconStore.maxDimension) / 4, "must follow the 4:1 pixel aspect")
    }

    /// The loader scales the logical size to a 16pt longest edge rather than
    /// forcing a square: SwiftUI's `scaledToFit` reads its aspect from
    /// `image.size`, so a square would stretch a wordmark to fill the frame.
    func testFittedSizePreservesAspectForTheLoader() throws {
        let wide = try XCTUnwrap(AgentIconStore.fittedSize(for: bitmap(width: 2000, height: 500), longEdge: 16))
        XCTAssertEqual(wide, NSSize(width: 16, height: 4))
        let tall = try XCTUnwrap(AgentIconStore.fittedSize(for: bitmap(width: 500, height: 2000), longEdge: 16))
        XCTAssertEqual(tall, NSSize(width: 4, height: 16))
        let square = try XCTUnwrap(AgentIconStore.fittedSize(for: bitmap(width: 640, height: 640), longEdge: 16))
        XCTAssertEqual(square, NSSize(width: 16, height: 16))
    }

    /// An extreme ratio must still round to a visible edge, never 0 (which
    /// `NSBitmapImageRep` would reject, silently failing the whole import).
    func testFittedSizeNeverCollapsesAnEdgeToZero() throws {
        let sliver = try XCTUnwrap(AgentIconStore.fittedSize(for: bitmap(width: 4000, height: 1), longEdge: 16))
        XCTAssertEqual(sliver.height, 1)
        XCTAssertNotNil(AgentIconStore.normalizedPNG(from: bitmap(width: 4000, height: 1)))
    }

    // MARK: - Loader fallthrough

    /// The one line the whole feature hangs on: `AgentIcon.nsImage` falling
    /// through from the bundle to the store. Without this test, deleting that
    /// clause leaves every other test in this file green.
    func testLoaderResolvesAnImportedIcon() throws {
        let source = try writeSourcePNG(width: 128, height: 128)
        let name = try AgentIconStore.importIcon(from: source, agentId: "custom-1")
        XCTAssertNotNil(AgentIcon.nsImage(asset: name), "imported icon must resolve through the loader")
    }

    func testLoaderReturnsNilForAnUnknownAsset() {
        XCTAssertNil(AgentIcon.nsImage(asset: "custom-1-nosuchfile.png"))
    }

    /// Imported names must never shadow a bundled mark. Guaranteed by the
    /// bundle lookup appending `.png` (so a stored `x.png` is sought as
    /// `x.png.png`) — which only holds while no builtin asset name carries an
    /// extension.
    func testBuiltinIconAssetsCarryNoExtension() {
        for template in AgentTemplate.builtin {
            guard let asset = template.iconAsset else { continue }
            XCTAssertFalse(asset.contains("."), "\(asset) would collide with the imported-icon namespace")
        }
    }

    func testRejectsZeroSizedSource() {
        XCTAssertNil(AgentIconStore.normalizedPNG(from: NSImage(size: .zero)))
    }

    // MARK: - importIcon

    func testImportStoresPNGNamedForTheAgent() throws {
        let source = try writeSourcePNG(width: 128, height: 128)
        let name = try AgentIconStore.importIcon(from: source, agentId: "custom-1")
        XCTAssertTrue(name.hasPrefix("custom-1-"))
        XCTAssertTrue(name.hasSuffix(".png"))
        XCTAssertNotNil(AgentIconStore.existingURL(for: name))
    }

    /// A JPEG source still lands as PNG — one format for the loader to decode.
    func testImportConvertsNonPNGSourceToPNG() throws {
        let jpeg = tempSource(ext: "jpg")
        let rep = try XCTUnwrap(bitmap(width: 100, height: 100).representations.first as? NSBitmapImageRep)
        try XCTUnwrap(rep.representation(using: .jpeg, properties: [:])).write(to: jpeg)
        let name = try AgentIconStore.importIcon(from: jpeg, agentId: "custom-2")
        XCTAssertTrue(name.hasSuffix(".png"))
        let stored = try Data(contentsOf: try XCTUnwrap(AgentIconStore.existingURL(for: name)))
        XCTAssertEqual(stored.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]), "stored file must be a PNG")
    }

    func testImportRejectsAFileThatIsNotAnImage() throws {
        let junk = tempSource(ext: "png")
        try Data("not an image".utf8).write(to: junk)
        XCTAssertThrowsError(try AgentIconStore.importIcon(from: junk, agentId: "custom-1"))
    }

    /// A decompression bomb: uniform pixels compress thousands-to-one, so
    /// this file sits far under the byte limit while declaring a resolution
    /// that would blow out memory on decode. The header check has to catch
    /// it — reaching `NSImage(contentsOf:)` is already too late.
    func testImportRejectsADecompressionBomb() throws {
        let bomb = try writeSourcePNG(width: 6000, height: 6000)
        let bytes = try XCTUnwrap(bomb.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(
            bytes, AgentIconStore.maxSourceBytes,
            "the byte limit must not be what rejects this, or the test proves nothing"
        )
        XCTAssertThrowsError(try AgentIconStore.importIcon(from: bomb, agentId: "custom-1")) { error in
            XCTAssertEqual(error as? AgentIconStore.ImportError, .tooManyPixels)
        }
    }

    /// The ceiling has to leave normal high-resolution logos alone.
    func testImportAcceptsALargeButReasonableLogo() throws {
        let source = try writeSourcePNG(width: 1024, height: 1024)
        XCTAssertNoThrow(try AgentIconStore.importIcon(from: source, agentId: "custom-1"))
    }

    /// Ids come from settings.json, which the user can hand-edit — a
    /// traversal in the id must not let the file escape the icons directory.
    func testImportSanitizesPathSeparatorsOutOfTheAgentId() throws {
        let source = try writeSourcePNG(width: 32, height: 32)
        let name = try AgentIconStore.importIcon(from: source, agentId: "../../evil")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(".."))
        XCTAssertNotNil(AgentIconStore.existingURL(for: name))
    }

    // MARK: - prune / existingURL

    func testPruneDropsUnreferencedIconsAndKeepsLiveOnes() throws {
        let source = try writeSourcePNG(width: 32, height: 32)
        let live = try AgentIconStore.importIcon(from: source, agentId: "custom-1")
        let orphan = try AgentIconStore.importIcon(from: source, agentId: "custom-2")
        AgentIconStore.prune(keeping: [CustomAgentData(id: "custom-1", iconAsset: live)])
        XCTAssertNotNil(AgentIconStore.existingURL(for: live))
        XCTAssertNil(AgentIconStore.existingURL(for: orphan))
    }

    /// The bulk paths the old per-agent prefix delete missed entirely:
    /// reset-to-defaults, and a settings.json edited to drop agents.
    func testPruneReclaimsEverythingWhenAllAgentsAreGone() throws {
        let source = try writeSourcePNG(width: 32, height: 32)
        let a = try AgentIconStore.importIcon(from: source, agentId: "custom-1")
        let b = try AgentIconStore.importIcon(from: source, agentId: "custom-2")
        AgentIconStore.prune(keeping: [])
        XCTAssertNil(AgentIconStore.existingURL(for: a))
        XCTAssertNil(AgentIconStore.existingURL(for: b))
    }

    /// Ids that share a hyphen-prefix (`claude` / `claude-fast`) or collapse
    /// onto one sanitized token (`my.agent` / `my agent`) both cross-deleted
    /// under prefix matching. Keying on the exact stored name makes the whole
    /// class unrepresentable.
    func testPruneNeverCrossDeletesBetweenRelatedIds() throws {
        let source = try writeSourcePNG(width: 32, height: 32)
        for (a, b) in [("claude", "claude-fast"), ("my.agent", "my agent")] {
            let iconA = try AgentIconStore.importIcon(from: source, agentId: a)
            let iconB = try AgentIconStore.importIcon(from: source, agentId: b)
            AgentIconStore.prune(keeping: [
                CustomAgentData(id: a, iconAsset: iconA),
                CustomAgentData(id: b, iconAsset: iconB),
            ])
            XCTAssertNotNil(AgentIconStore.existingURL(for: iconA), "\(a) lost its icon to \(b)")
            XCTAssertNotNil(AgentIconStore.existingURL(for: iconB), "\(b) lost its icon to \(a)")
        }
    }

    /// A re-import must not disturb the icon still in use until the new one is
    /// safely on disk — the old delete-then-write order destroyed it when the
    /// write failed.
    func testReimportLeavesTheOldIconUntilPruneRuns() throws {
        let source = try writeSourcePNG(width: 64, height: 64)
        let first = try AgentIconStore.importIcon(from: source, agentId: "custom-1")
        let second = try AgentIconStore.importIcon(from: source, agentId: "custom-1")
        XCTAssertNotEqual(first, second)
        XCTAssertNotNil(AgentIconStore.existingURL(for: first), "the old icon survives the write")
        AgentIconStore.prune(keeping: [CustomAgentData(id: "custom-1", iconAsset: second)])
        XCTAssertNil(AgentIconStore.existingURL(for: first))
        XCTAssertNotNil(AgentIconStore.existingURL(for: second))
    }

    /// Pruning deletes files, so it must stay inert in a process that never
    /// opted in — otherwise a test reaching `save()` sweeps the developer's
    /// own imported logos.
    func testPruneIsInertWithoutAnOptIn() throws {
        let source = try writeSourcePNG(width: 32, height: 32)
        let icon = try AgentIconStore.importIcon(from: source, agentId: "custom-1")
        let dir = try XCTUnwrap(tempDir)
        AgentIconStore.directoryOverride = nil
        defer { AgentIconStore.directoryOverride = dir }
        AgentIconStore.prune(keeping: [])
        AgentIconStore.directoryOverride = dir
        XCTAssertNotNil(AgentIconStore.existingURL(for: icon))
    }

    /// A hand-deleted file must read as "no icon" so the agent falls back to
    /// its SF Symbol instead of rendering an empty frame.
    func testExistingURLIsNilForAMissingFile() {
        XCTAssertNil(AgentIconStore.existingURL(for: "custom-1-deadbeef.png"))
    }

    func testExistingURLRejectsPathTraversal() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        XCTAssertNil(AgentIconStore.existingURL(for: "../../../etc/passwd"))
        XCTAssertNil(AgentIconStore.existingURL(for: ""))
    }

    // MARK: - Helpers

    private func bitmap(width: Int, height: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    /// Cleanup is registered here rather than in `writeSourcePNG` so every
    /// temp source is covered — two callers write through this directly.
    private func tempSource(ext: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpad-icon-src-\(UUID().uuidString).\(ext)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeSourcePNG(width: Int, height: Int) throws -> URL {
        let url = tempSource(ext: "png")
        let rep = try XCTUnwrap(bitmap(width: width, height: height).representations.first as? NSBitmapImageRep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func pixelSize(of png: Data) throws -> (Int, Int) {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    /// Fraction of fully-opaque pixels — distinguishes "rasterised something"
    /// from "emitted a correctly-sized transparent rectangle".
    private func opaqueFraction(of png: Data) throws -> Double {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        var opaque = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 8) {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.99 { opaque += 1 }
            }
        }
        let sampled = ((rep.pixelsWide + 7) / 8) * ((rep.pixelsHigh + 7) / 8)
        return sampled == 0 ? 0 : Double(opaque) / Double(sampled)
    }
}
