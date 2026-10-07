import AppKit
import Quartz
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class FilePreviewReloadTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("preview-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func png(width: Int = 8) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let color = NSColor(deviceRed: 0.1, green: 0.4, blue: 0.8, alpha: 1)
        for y in 0..<8 {
            for x in 0..<width { bitmap.setColor(color, atX: x, y: y) }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func open(_ model: FilePreviewModel) async throws -> URL {
        let url = dir.appendingPathComponent("image.png")
        try png().write(to: url)
        model.open(url)
        try await wait { model.content != nil }
        return url
    }

    private func wait(
        file: StaticString = #filePath, line: UInt = #line,
        until condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Preview did not settle", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testReloadOfUnchangedImageDoesNotPublishNewRevision() async throws {
        let model = FilePreviewModel()
        defer { model.close() }
        _ = try await open(model)
        let revision = model.revision
        let content = model.content

        for _ in 0..<3 {
            model.reload()
            try await Task.sleep(for: .milliseconds(200))
        }

        XCTAssertEqual(model.revision, revision, "An unchanged file must not restart its preview")
        XCTAssertEqual(model.content, content, "The decoded image must be reused")
    }

    func testAttributeChangesDoNotReloadImage() async throws {
        let model = FilePreviewModel()
        defer { model.close() }
        let url = try await open(model)
        let revision = model.revision
        let content = model.content

        // Real vnode .attrib events, without changing the bytes or mtime.
        for permissions in [0o600, 0o644, 0o600] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            try await Task.sleep(for: .milliseconds(300))
        }

        XCTAssertEqual(model.revision, revision, "Metadata changes must not clear and reload the image")
        XCTAssertEqual(model.content, content)
    }

    func testTouchAndIdenticalInPlaceWritesKeepDecodedImage() async throws {
        let model = FilePreviewModel()
        defer { model.close() }
        let url = try await open(model)
        let revision = model.revision
        let content = model.content
        let bytes = try Data(contentsOf: url)

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.revision, revision)
        XCTAssertEqual(model.content, content)

        try bytes.write(to: url)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.revision, revision)
        XCTAssertEqual(model.content, content)
    }

    func testAtomicReplacementWithPreservedSizeAndMtimeIsDetected() async throws {
        let model = FilePreviewModel()
        defer { model.close() }
        let url = dir.appendingPathComponent("note.txt")
        try Data("before".utf8).write(to: url)
        var before = stat()
        XCTAssertEqual(stat(url.path, &before), 0)
        model.open(url)
        try await wait { model.content != nil }
        let revision = model.revision

        try Data("after!".utf8).write(to: url, options: .atomic)
        // Preserve nanoseconds exactly; Date/FileManager would round them and
        // could make this pass without checking the replacement's inode.
        var times = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, url.path, &times, 0), 0)
        try await wait { model.revision > revision }
        guard case .text(let text, _, _, _) = model.content else { return XCTFail("Expected updated text") }
        XCTAssertEqual(text, "after!")
        XCTAssertEqual(model.revision, revision + 1)
    }

    func testReloadBurstAndCloseDoNotPublishStaleLoads() async throws {
        let model = FilePreviewModel()
        defer { model.close() }
        let url = dir.appendingPathComponent("image.png")
        try png(width: 32).write(to: url)
        model.open(url)
        for _ in 0..<100 { model.reload() }
        try await wait { model.content != nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.revision, 1, "Coalesce requests arriving while the decoder is busy")

        model.reload()
        model.close()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.content)
        XCTAssertNil(model.url)
        XCTAssertEqual(model.revision, 1)

        model.open(url)
        try await wait { model.content != nil }
        XCTAssertEqual(model.revision, 2, "Closing must also reset the file/image cache")
    }

    func testInPlaceTextWriteWithSameSizeAndMtimeIsDetected() async throws {
        let model = FilePreviewModel()
        defer { model.close() }
        let url = dir.appendingPathComponent("same-stamp.txt")
        try Data("before".utf8).write(to: url)
        model.open(url)
        try await wait { model.content != nil }
        let revision = model.revision
        try overwritePreservingStamp(url, with: Data("after!".utf8))
        // Real vnode writes may be coalesced with the attrib from utimensat.
        try await wait { model.revision > revision }
        guard case .text(let text, _, _, _) = model.content else { return XCTFail("Expected text") }
        XCTAssertEqual(text, "after!")
    }

    private func overwritePreservingStamp(_ url: URL, with bytes: Data) throws {
        var before = stat(), after = stat()
        XCTAssertEqual(stat(url.path, &before), 0)
        XCTAssertEqual(bytes.count, Int(before.st_size))
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: bytes)
        try handle.close()
        var times = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, url.path, &times, 0), 0)
        XCTAssertEqual(stat(url.path, &after), 0)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_size, before.st_size)
        XCTAssertEqual(after.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec)
        XCTAssertEqual(after.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec)
    }

    func testInPlaceImageWriteWithSameSizeAndMtimeChecksDigest() async throws {
        let model = FilePreviewModel()
        defer { model.close() }
        let url = dir.appendingPathComponent("same-stamp.png")
        let first = try png(width: 8), second = try png(width: 16)
        // ImageIO accepts bytes after IEND. Padding equalizes encoded sizes.
        let count = max(first.count, second.count)
        let paddedFirst = first + Data(repeating: 0, count: count - first.count)
        let paddedSecond = second + Data(repeating: 0, count: count - second.count)
        try paddedFirst.write(to: url)
        model.open(url)
        try await wait { model.content != nil }
        let revision = model.revision
        try overwritePreservingStamp(url, with: paddedSecond)
        try await wait { model.revision > revision }
        guard case .image(let image) = model.content else { return XCTFail("Expected bitmap") }
        XCTAssertEqual(image.cgImage.width, 16)
        let content = model.content
        try overwritePreservingStamp(url, with: paddedSecond)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.revision, revision + 1, "identical bytes reuse the decoded image")
        XCTAssertEqual(model.content, content)
    }

    func testAttributeOnlySkipsReadButCoalescedWriteAndExtendDoNot() async throws {
        let reads = LockedCounter()
        let model = FilePreviewModel(didRead: { _ in reads.increment() })
        defer { model.close() }
        _ = try await open(model)
        let initial = reads.value
        model.fileDidChange(.attrib)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(reads.value, initial)
        for event: DispatchSource.FileSystemEvent in [.write, .extend] {
            let before = reads.value
            model.fileDidChange(event)
            model.fileDidChange(.attrib)
            try await wait { reads.value > before }
        }
    }

    func testGrowingTextPublishesSnapshotEvenWhenEveryReadRacesAnAppend() async throws {
        for ext in ["txt", "md", "html"] {
            let url = dir.appendingPathComponent("growing.\(ext)")
            try Data("initial snapshot\n".utf8).write(to: url)
            let model = FilePreviewModel(didRead: { url in
                // Deterministically change the stamp between read and validation.
                guard let handle = try? FileHandle(forWritingTo: url) else { return }
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data("appended\n".utf8))
            })
            model.open(url)
            try await wait { model.content != nil }
            switch model.content {
            case .text(let text, _, _, _), .markdown(let text, _), .html(let text):
                XCTAssertTrue(text.hasPrefix("initial snapshot\n"))
            default: XCTFail("A bounded text snapshot must publish during append: \(ext)")
            }
            let revision = model.revision
            try await wait { model.revision > revision }
            model.close()
        }
    }

    func testWriteReasonSurvivesAttributesWhileLoaderIsBusy() async throws {
        let gate = Gate(), reads = LockedCounter(), entered = expectation(description: "loader busy")
        let model = FilePreviewModel(didRead: { _ in
            reads.increment()
            if reads.value == 2 { entered.fulfill(); gate.pass() }
        })
        defer { gate.open(); model.close() }
        _ = try await open(model)
        gate.close()
        model.reload()
        await fulfillment(of: [entered], timeout: 3)
        model.reload(reason: .contents)
        model.reload(reason: .attributes)
        gate.open()
        try await wait { reads.value > 2 }
        XCTAssertEqual(model.revision, 1, "hashing unchanged bytes still reuses the bitmap")
    }

    func testContinuousAppendsHaveAMaximumReloadDelay() async throws {
        let url = dir.appendingPathComponent("stream.txt")
        try Data("start\n".utf8).write(to: url)
        let model = FilePreviewModel()
        defer { model.close() }
        model.open(url)
        try await wait { model.content != nil }
        let revision = model.revision
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        let started = ContinuousClock.now
        var firstUpdate: Duration?
        // 25ms is below the 150ms debounce, including after the first update.
        while ContinuousClock.now - started < .seconds(2.3) {
            try handle.write(contentsOf: Data("entry\n".utf8))
            try await Task.sleep(for: .milliseconds(25))
            if model.revision > revision, firstUpdate == nil { firstUpdate = ContinuousClock.now - started }
        }
        XCTAssertNotNil(firstUpdate, "continuous writes must not starve reloads")
        if let firstUpdate { XCTAssertLessThan(firstUpdate, .seconds(1.5), "1s deadline with scheduling tolerance") }
        XCTAssertGreaterThanOrEqual(model.revision, revision + 2, "keep publishing during the stream")
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    func testIdenticalAtomicSaveIsIgnoredButWatcherFollowsReplacement() async throws {
        let model = FilePreviewModel()
        defer { model.close() }
        let url = try await open(model)
        let revision = model.revision
        let content = model.content
        let bytes = try Data(contentsOf: url)

        try bytes.write(to: url, options: .atomic)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.revision, revision, "A new inode with identical bytes needs no new image")
        XCTAssertEqual(model.content, content)

        try png(width: 12).write(to: url, options: .atomic)
        try await wait { model.revision > revision }
        XCTAssertEqual(model.revision, revision + 1)
        XCTAssertNotEqual(model.content, content)

        // The replacement's descriptor must keep observing subsequent saves.
        try png(width: 16).write(to: url)
        try await wait { model.revision > revision + 1 }
        XCTAssertEqual(model.revision, revision + 2)
    }

    func testSiblingWritesDoNotReloadImage() async throws {
        let model = FilePreviewModel()
        defer { model.close() }
        let url = try await open(model)
        let revision = model.revision
        let content = model.content

        for i in 0..<12 {
            // Atomic saves also create/remove entries in the watched tree directory.
            for name in ["agent.log", ".DS_Store"] {
                try Data("entry \(i)".utf8).write(to: dir.appendingPathComponent(name), options: .atomic)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.revision, revision)
        XCTAssertEqual(model.content, content)

        try png(width: 12).write(to: url)
        try await wait { model.revision > revision }
        XCTAssertEqual(model.revision, revision + 1, "The selected file must still reload")
    }

    func testIncompleteAndMissingImageKeepLastGoodFrameUntilReplacementIsReady() async throws {
        let model = FilePreviewModel()
        defer { model.close() }
        let url = try await open(model)
        let revision = model.revision
        let content = model.content

        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.content, content, "A partial write must not blank the image")
        XCTAssertEqual(model.revision, revision)

        try FileManager.default.removeItem(at: url)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.content, content, "Keep the frame through delete/recreate saves")
        XCTAssertEqual(model.revision, revision)

        try png(width: 16).write(to: url, options: .atomic)
        try await wait { model.revision > revision }
        XCTAssertEqual(model.revision, revision + 1)
        XCTAssertNotEqual(model.content, content)
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    func testMountedImageStaysIdleDuringSiblingFileChurn() async throws {
        let model = FilePreviewModel()
        defer { model.close() }
        _ = try await open(model)
        let revision = model.revision
        let content = model.content
        let host = NSHostingView(rootView: FilePreviewPanel(model: model, root: dir))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()

        for i in 0..<8 {
            try Data("entry \(i)".utf8).write(to: dir.appendingPathComponent("agent.log"), options: .atomic)
            try Data([UInt8(i)]).write(to: dir.appendingPathComponent(".DS_Store"), options: .atomic)
            host.rootView = FilePreviewPanel(model: model, root: dir)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.revision, revision, "Mounting/redrawing the preview must not cause a file-event feedback loop")
        XCTAssertEqual(model.content, content)
    }

    func testImageViewAndImageStayStableAcrossParentUpdates() async throws {
        let model = FilePreviewModel()
        defer { model.close() }
        let url = try await open(model)
        let host = NSHostingView(rootView: FilePreviewPanel(model: model, root: dir))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendants(QLPreviewView.self, in: host).isEmpty, "Images must not use Quick Look's asynchronous file preview")
        let view = try XCTUnwrap(descendants(NSImageView.self, in: host).first)
        let image = try XCTUnwrap(view.image)

        for _ in 0..<5 {
            host.rootView = FilePreviewPanel(model: model, root: dir)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(descendants(NSImageView.self, in: host).first === view)
            XCTAssertTrue(view.image === image, "An unrelated redraw must not allocate a new NSImage")
        }

        let revision = model.revision
        try png(width: 16).write(to: url, options: .atomic)
        XCTAssertTrue(view.image === image, "Keep displaying the old image while decoding")
        try await wait {
            host.layoutSubtreeIfNeeded()
            return model.revision > revision && view.image !== image
        }
        XCTAssertTrue(descendants(NSImageView.self, in: host).first === view)
        XCTAssertEqual(view.image?.size.width, 16)
        XCTAssertEqual(view.image?.size.height, 8)
    }
}
