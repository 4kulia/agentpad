import AppKit
import GhosttyKit
import XCTest
@testable import AgentPadKit

@MainActor
final class TerminalLinkTests: XCTestCase {
    func testQuotedAndMissingFilenameLocations() throws {
        let cwd = URL(fileURLWithPath: "/tmp/link-project")
        for raw in ["`docs/a b.md:12:3`", "\"docs/a b.md\":12:3", "'docs/a b.md':12:3"] {
            let target = TerminalOpenTargetResolver.resolve(raw, currentDirectory: cwd, fileExists: { _ in false })
            XCTAssertEqual(target, .file(.init(url: cwd.appendingPathComponent("docs/a b.md"), line: 12, column: 3)))
        }
        XCTAssertEqual(TerminalOpenTargetResolver.resolve("missing.swift:42", currentDirectory: cwd, fileExists: { _ in false }),
            .file(.init(url: cwd.appendingPathComponent("missing.swift"), line: 42, column: nil)))
    }

    func testTextRangesKeepQuotedSpacesAndExcludeSurroundingProse() throws {
        for value in ["\"docs/a  b.md\":12:3", "`docs/папка с пробелами/file.html`", "'~/a b/'", "main.swift:42:2", "./folder/", "../README.md"] {
            let text = "See \(value), next"
            let range = (text as NSString).range(of: value)
            for i in range.location..<NSMaxRange(range) {
                XCTAssertEqual(TerminalTextLinkDetector.link(in: text, at: i)?.value, value, "\(value), offset \(i)")
            }
            XCTAssertNil(TerminalTextLinkDetector.link(in: text, at: NSMaxRange(range)))
        }
        XCTAssertNil(TerminalTextLinkDetector.link(in: "https://example.com/a.swift", at: 15))
        XCTAssertNil(TerminalTextLinkDetector.link(in: "ordinary text", at: 3))
        let markdown = "See [source](Sources/main.swift:9), done"
        let pathOffset = (markdown as NSString).range(of: "Sources/").location
        XCTAssertEqual(TerminalTextLinkDetector.link(in: markdown, at: pathOffset)?.value, "Sources/main.swift:9")
    }

    func testProcessCwdWinsOverStaleOSC7Fallback() {
        XCTAssertEqual(TerminalWorkingDirectory.resolve(pid: getpid(), fallback: URL(fileURLWithPath: "/tmp/stale"))?.standardizedFileURL,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL)
        let fallback = URL(fileURLWithPath: "/tmp/fallback")
        XCTAssertEqual(TerminalWorkingDirectory.resolve(pid: nil, fallback: fallback), fallback)
    }

    func testSourceLocationsClampAndUseUTF16ForAppKit() {
        let text = "one\r\n🙂e\u{301}中x\r\nlast\n"
        XCTAssertEqual(FilePreviewLocation(line: 2, column: nil).range(in: text), NSRange(location: 5, length: 6))
        XCTAssertEqual(FilePreviewLocation(line: 2, column: 3).range(in: text), NSRange(location: 9, length: 1))
        XCTAssertEqual(FilePreviewLocation(line: 2, column: 999).range(in: text), NSRange(location: 11, length: 0))
        XCTAssertEqual(FilePreviewLocation(line: Int.max, column: 1).range(in: text), NSRange(location: 18, length: 0))
        XCTAssertEqual(FilePreviewLocation(line: 1, column: 1).range(in: ""), NSRange(location: 0, length: 0))
    }

    func testPreviewReopensSameFileAtNewLocationAndResetsForOrdinaryOpen() async throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("readme.md")
        try Data("# Title\nline two\nline three".utf8).write(to: url)
        let model = FilePreviewModel()
        defer { model.close() }
        model.open(url, line: 2, column: 3)
        let first = try XCTUnwrap(model.sourceLocation)
        XCTAssertTrue(model.showsMarkdownSource)
        model.open(url, line: 3)
        XCTAssertEqual(model.sourceLocation?.line, 3)
        XCTAssertNotEqual(model.sourceLocation?.id, first.id)
        let view = NSTextView()
        view.string = "first\nsecond\nthird"
        CodeTextView.reveal(try XCTUnwrap(model.sourceLocation), in: view)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 13, length: 5))
        model.open(url)
        XCTAssertNil(model.sourceLocation)
        XCTAssertFalse(model.showsMarkdownSource)
        let missing = dir.appendingPathComponent("missing.swift")
        model.open(missing)
        for _ in 0..<100 where model.content == nil { try await Task.sleep(for: .milliseconds(10)) }
        guard case .unreadable(let reason) = model.content else { return XCTFail("missing-file explanation") }
        XCTAssertTrue(reason.contains("File not found"))
    }

    func testHTMLHasRenderedPreviewAndLocalStylesheetsStayInsideRoot() throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = dir.appendingPathComponent("page.html")
        try Data("<h1>Hello</h1>".utf8).write(to: html)
        XCTAssertEqual(FilePreviewModel.load(html), .html("<h1>Hello</h1>"))
        let css = dir.appendingPathComponent("style.css")
        let bytes = Data("h1 { color: red }".utf8)
        try bytes.write(to: css)
        XCTAssertEqual(LocalResourceHandler.resource(at: css.path, root: dir, allowsStylesheets: true), bytes)
        XCTAssertNil(LocalResourceHandler.resource(at: css.path, root: dir))
        XCTAssertNil(LocalResourceHandler.resource(at: html.path, root: dir, allowsStylesheets: true))
        XCTAssertTrue(HTMLPreview.document("<script>void 0</script>").contains("default-src 'none'"))
    }

    func testStoreRoutesFilesAndFoldersToOriginatingWindowAfterTabTransfer() throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = store(dir: dir)
        let b = WorkspaceStore(persistence: InMemoryPersistence(), engineFactory: { TestEngine() },
            optionsProvider: { _ in nil }, resumeProvider: { false }, peerStores: { [a] }, claudeProjectsRoot: dir)
        let session = try XCTUnwrap(a.active?.activeSession)
        let engine = try XCTUnwrap(session.engine as? TestEngine)
        let reference = TerminalFileReference(url: dir.appendingPathComponent("source.swift"), line: 42, column: 7)
        engine.onOpenFile?(reference)
        XCTAssertEqual(FilePreviewModel.for(a).url, reference.url.standardizedFileURL)
        XCTAssertEqual(FilePreviewModel.for(a).sourceLocation?.line, 42)
        XCTAssertFalse(FilePreviewModel.for(b).isOpen)
        FilePreviewModel.for(a).close()
        let workspace = try XCTUnwrap(b.active)
        let pane = try XCTUnwrap(workspace.activePane)
        XCTAssertTrue(b.handleTabDrop(droppedId: session.id, to: pane, at: pane.tabs.count, in: workspace))
        engine.onOpenFile?(reference)
        XCTAssertFalse(FilePreviewModel.for(a).isOpen)
        XCTAssertEqual(FilePreviewModel.for(b).url, reference.url.standardizedFileURL)
        engine.onOpenFile?(.init(url: dir, line: nil, column: nil))
        XCTAssertEqual(b.sidebarContent, .files)
        XCTAssertEqual(b.sidebarMode, .full)
        XCTAssertEqual(b.fileTreeRoot?.standardizedFileURL, dir.standardizedFileURL)
        FilePreviewModel.for(b).close()
    }

    func testNativePlainQuotedAndTildeLinksOpenOnlyAfterCommandClick() async throws {
        let t = try LinkTerminal()
        t.view.currentDirectory = URL(fileURLWithPath: "/tmp/links")
        let paths = ["docs/preview.html:42:7", "\"docs/a  b.md\":12", "`docs/папка с пробелами/a.swift:9:2`", "~/Pictures/image.png", "./folder/", "missing.swift:8"]
        for path in paths { t.feed(path + "\r\n") }
        await t.drain()
        XCTAssertTrue(t.files.isEmpty)
        for (row, path) in paths.enumerated() {
            let before = t.files.count
            t.view.mouseMoved(with: try t.mouse(.mouseMoved, column: 4, row: row, mods: [.command]))
            await t.drain()
            XCTAssertEqual(t.files.count, before, "hover never opens")
            XCTAssertNotNil(t.hover)
            try t.click(column: 4, row: row, mods: [])
            await t.drain()
            XCTAssertEqual(t.files.count, before, "plain click never opens")
            try t.click(column: 4, row: row)
            await t.drain()
            XCTAssertEqual(t.files.count, before + 1, path)
            if case .file(let expected) = TerminalOpenTargetResolver.resolve(path, currentDirectory: t.view.currentDirectory) {
                XCTAssertEqual(t.files.last, expected)
            } else { XCTFail(path) }
        }
        XCTAssertTrue(t.urls.isEmpty)
        await t.close()
    }

    func testNativeOSC8OwnsPathShapedLabelAndExternalURLUsesBrowser() async throws {
        let t = try LinkTerminal()
        t.view.currentDirectory = URL(fileURLWithPath: "/tmp/links")
        t.feed("\u{1B}]8;;docs/actual.md:8:2\u{1B}\\\"docs/wrong  file.swift\"\u{1B}]8;;\u{1B}\\\r\n")
        t.feed("\u{1B}]8;;https://example.com/actual\u{1B}\\docs/wrong.md\u{1B}]8;;\u{1B}\\\r\n")
        t.feed("https://example.com/plain\r\n")
        await t.drain()
        XCTAssertTrue(t.files.isEmpty)
        XCTAssertTrue(t.urls.isEmpty)
        try t.click(column: 4, row: 0, mods: [])
        await t.drain()
        XCTAssertTrue(t.files.isEmpty, "an OSC 8 link also requires Command-click")
        try t.click(column: 4, row: 0)
        try t.click(column: 4, row: 1)
        try t.click(column: 12, row: 2)
        await t.drain()
        XCTAssertEqual(t.files.map(\.url.lastPathComponent), ["actual.md"])
        XCTAssertEqual(t.files.first?.line, 8)
        XCTAssertEqual(t.files.first?.column, 2)
        XCTAssertEqual(t.urls.map(\.absoluteString), ["https://example.com/actual", "https://example.com/plain"])
        await t.close()
    }

    func testNativeAlternateScreenDragAndOutputChangesDoNotAccidentallyOpen() async throws {
        let t = try LinkTerminal()
        t.view.currentDirectory = URL(fileURLWithPath: "/tmp/links")
        t.feed("\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1006h`docs/file name.md`\r\n")
        await t.drain()
        try t.click(column: 8, row: 0)
        await t.drain()
        XCTAssertEqual(t.files.count, 1)
        t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 4, row: 0, mods: [.command]))
        t.view.mouseDragged(with: try t.mouse(.leftMouseDragged, column: 11, row: 0, mods: [.command]))
        t.view.mouseUp(with: try t.mouse(.leftMouseUp, column: 11, row: 0, mods: [.command]))
        XCTAssertEqual(t.files.count, 1)
        t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 4, row: 0, mods: [.command]))
        t.feed("\u{1B}[H\u{1B}[2K`docs/different.md`")
        t.view.mouseUp(with: try t.mouse(.leftMouseUp, column: 4, row: 0, mods: [.command]))
        XCTAssertEqual(t.files.count, 1)
        t.view.isRemoteSessionProvider = { true }
        try t.click(column: 4, row: 0)
        await t.drain()
        XCTAssertEqual(t.files.count, 1, "remote path must not open a local namesake")
        await t.close()
    }

    func testNativeSoftWrappedQuotedPathAndCommandRelease() async throws {
        let t = try LinkTerminal()
        t.view.currentDirectory = URL(fileURLWithPath: "/tmp/links")
        var size = ghostty_surface_size_s()
        XCTAssertTrue(ghostty_surface_set_grid_size(t.surface, 30, 12, &size))
        let target = "`docs/a long folder/another folder/пример.swift`:42:2"
        t.feed(target + "\r\n")
        await t.drain()
        t.view.mouseMoved(with: try t.mouse(.mouseMoved, column: 4, row: 1, mods: [.command]))
        XCTAssertEqual(t.hover, target)
        t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 4, row: 1, mods: [.command]))
        t.view.mouseUp(with: try t.mouse(.leftMouseUp, column: 4, row: 1, mods: []))
        XCTAssertEqual(t.files.first?.url.lastPathComponent, "пример.swift")
        XCTAssertEqual(t.files.first?.line, 42)
        XCTAssertEqual(t.files.first?.column, 2)
        XCTAssertNil(t.hover)
        await t.close()
    }

    func testNativeOSC8IsStillAuthoritativeAfterLeavingAndReenteringCell() async throws {
        let t = try LinkTerminal()
        t.view.currentDirectory = URL(fileURLWithPath: "/tmp/links")
        t.feed("\u{1B}]8;;https://example.com/authoritative\u{1B}\\\"docs/wrong  file.swift\"\u{1B}]8;;\u{1B}\\")
        await t.drain()
        try t.click(column: 4, row: 0)
        try t.click(column: 4, row: 0)
        t.view.fileLinks.clear()
        try t.click(column: 4, row: 0)
        await t.drain()
        XCTAssertTrue(t.files.isEmpty)
        XCTAssertEqual(t.urls.count, 3)
        await t.close()
    }

    func testNativeOSC7KeepsTabDirectoriesSeparateAndFileURLKeepsLocation() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        for dir in [a, b] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let first = try LinkTerminal(), second = try LinkTerminal()
        first.feed("same.swift:2\r\n\u{1B}]7;file://localhost\(a.path)\u{1B}\\")
        second.feed("same.swift:2\r\n\u{1B}]7;file://localhost\(b.path)\u{1B}\\")
        await first.drain()
        await second.drain()
        try first.click(column: 3, row: 0)
        try second.click(column: 3, row: 0)
        XCTAssertEqual(first.files.last?.url, a.appendingPathComponent("same.swift").standardizedFileURL)
        XCTAssertEqual(second.files.last?.url, b.appendingPathComponent("same.swift").standardizedFileURL)
        first.feed("\u{1B}]7;file://localhost\(b.path)\u{1B}\\")
        await first.drain()
        try first.click(column: 3, row: 0)
        XCTAssertEqual(first.files.last?.url, b.appendingPathComponent("same.swift").standardizedFileURL)
        let fileURL = root.appendingPathComponent("a b.md")
        first.feed("\u{1B}]8;;\(fileURL.absoluteString)#L6C2\u{1B}\\document\u{1B}]8;;\u{1B}\\")
        await first.drain()
        try first.click(column: 3, row: 1)
        await first.drain()
        XCTAssertEqual(first.files.last, .init(url: fileURL.standardizedFileURL, line: 6, column: 2))
        await first.close()
        await second.close()
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-links-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store(dir: URL) -> WorkspaceStore {
        WorkspaceStore(persistence: InMemoryPersistence(), engineFactory: { TestEngine() },
            optionsProvider: { _ in nil }, resumeProvider: { false }, claudeProjectsRoot: dir)
    }
}

@MainActor
final class LinkTerminal {
    let window: NSWindow
    let view: GhosttySurfaceView
    let app: ghostty_app_t
    let config: ghostty_config_t
    var files: [TerminalFileReference] = []
    var urls: [URL] = []
    var hover: String?
    var surface: ghostty_surface_t { view.surface! }

    init() throws {
        _ = NSApplication.shared
        _ = try XCTUnwrap(LibghosttyApp.shared.app)
        let config = try XCTUnwrap(ghostty_config_new())
        self.config = config
        let settings = "font-family = Menlo\ncopy-on-select = false\n"
        settings.withCString { ghostty_config_load_string(config, $0, UInt(settings.utf8.count), "links-test") }
        TerminalLinkInteraction.configure(config)
        ghostty_config_finalize(config)
        var runtime = LibghosttyApp.runtimeConfig()
        app = try XCTUnwrap(ghostty_app_new(&runtime, config))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 550),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        view = GhosttySurfaceView(frame: NSRect(x: 0, y: 0, width: 900, height: 550))
        window.contentView = view
        var sc = ghostty_surface_config_new()
        sc.scale_factor = Double(window.backingScaleFactor)
        sc.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        _ = try XCTUnwrap(view.attachSurface(app: app, config: &sc))
        window.makeFirstResponder(view)
        ghostty_surface_set_focus(surface, true)
        view.onOpenFile = { [weak self] in self?.files.append($0) }
        view.openExternalURL = { [weak self] in self?.urls.append($0) }
        view.onLinkHover = { [weak self] in self?.hover = $0 }
    }

    func feed(_ text: String) {
        text.withCString { ghostty_surface_process_output(surface, $0, UInt(text.utf8.count)) }
    }
    func drain() async {
        // Production ticks the shared app. This fixture owns an isolated app,
        // whose queued actions (notably OSC 7 PWD) must be drained explicitly.
        ghostty_app_tick(app)
        try? await Task.sleep(for: .milliseconds(30))
    }
    func click(column: Int, row: Int, mods: NSEvent.ModifierFlags = [.command]) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, column: column, row: row, mods: mods))
        view.mouseUp(with: try mouse(.leftMouseUp, column: column, row: row, mods: mods))
    }
    func mouse(_ type: NSEvent.EventType, column: Int, row: Int, mods: NSEvent.ModifierFlags) throws -> NSEvent {
        var grid = ghostty_surface_grid_metrics_s()
        XCTAssertTrue(ghostty_surface_grid_metrics(surface, &grid))
        let point = NSPoint(x: grid.padding_left + (Double(column) + 0.5) * grid.cell_width,
            y: view.bounds.height - grid.padding_top - (Double(row) + 0.5) * grid.cell_height)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: mods,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    func close() async {
        view.releaseSurface()
        await withCheckedContinuation { continuation in
            SurfaceTeardownCoordinator.shared.whenDrained { continuation.resume() }
        }
        window.contentView = nil
        window.orderOut(nil)
        ghostty_app_free(app)
        ghostty_config_free(config)
    }
}
