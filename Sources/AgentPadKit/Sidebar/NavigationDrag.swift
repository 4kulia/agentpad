import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A URL remains consumable by terminals and Finder. The extra type and live
/// token distinguish File Tree drags without guessing from paths or UI state.
@MainActor
enum InternalFileDrag {
    static let type = NSPasteboard.PasteboardType("app.agentpad.internal-file-drag")
    private(set) static var activeTokens: Set<UUID> = []

    static func begin(_ token: UUID) { activeTokens.insert(token) }
    static func end(_ token: UUID) { activeTokens.remove(token) }
    static func rejectsFolderDrop(hasMarker: Bool) -> Bool { hasMarker || !activeTokens.isEmpty }
    static func marker(_ token: UUID) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(token.uuidString, forType: type)
        return item
    }
}

/// AppKit supplies a completion callback even for Escape and an outside drop.
/// Clicks retain their normal single/double-click actions below the 6pt threshold.
struct NavigationDragSource: NSViewRepresentable {
    var title: String
    var writers: () -> [NSPasteboardWriting]
    var click: (Int) -> Void
    var began: () -> Void = {}
    var ended: () -> Void = {}

    func makeNSView(context: Context) -> Anchor { Anchor(source: self) }
    func updateNSView(_ view: Anchor, context: Context) { view.source = self }

    final class Anchor: NSView, NSDraggingSource {
        var source: NavigationDragSource
        init(source: NavigationDragSource) { self.source = source; super.init(frame: .zero) }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            let start = convert(event.locationInWindow, from: nil)
            while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let point = convert(next.locationInWindow, from: nil)
                if next.type == .leftMouseUp {
                    if bounds.contains(point) { source.click(event.clickCount) }
                    return
                }
                guard hypot(point.x - start.x, point.y - start.y) >= 6 else { continue }
                let title = source.title
                let image = NSImage(size: NSSize(width: max(90, bounds.width), height: 30), flipped: false) { rect in
                    NSColor.windowBackgroundColor.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                    (title as NSString).draw(in: rect.insetBy(dx: 8, dy: 7), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor
                    ])
                    return true
                }
                let items = source.writers().map { writer in
                    let item = NSDraggingItem(pasteboardWriter: writer)
                    item.setDraggingFrame(NSRect(origin: point, size: image.size), contents: image)
                    return item
                }
                beginDraggingSession(with: items, event: next, source: self)
                return
            }
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { [.copy, .move] }
        func draggingSession(_ session: NSDraggingSession, willBeginAt point: NSPoint) { source.began() }
        func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) { source.ended() }
    }
}

struct RailSurfaceDrop: DropDelegate {
    let store: WorkspaceStore
    func validateDrop(info: DropInfo) -> Bool {
        guard !InternalFileDrag.rejectsFolderDrop(hasMarker: info.hasItemsConforming(to: [InternalFileDrag.type.rawValue])) else { return false }
        return info.hasItemsConforming(to: [UTType.fileURL.identifier]) || store.draggedTab != nil
    }
    func dropEntered(info: DropInfo) {
        if validateDrop(info: info), store.draggedTab != nil { store.setRailDragTarget("list", entered: true) }
    }
    func dropExited(info: DropInfo) { store.setRailDragTarget("list", entered: false) }
    func performDrop(info: DropInfo) -> Bool {
        defer { store.finishNavigationDrag() }
        guard validateDrop(info: info), info.hasItemsConforming(to: [UTType.fileURL.identifier]) else { return false }
        for provider in info.itemProviders(for: [UTType.fileURL.identifier]) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    guard !store.isTerminated, isDirectory(url) else { return }
                    store.addWorkspace(workingDirectory: url)
                }
            }
        }
        return true
    }
}

struct HiddenRailDrop: DropDelegate {
    let store: WorkspaceStore
    func validateDrop(info: DropInfo) -> Bool {
        !store.leftNavigation.railVisible && store.draggedTab != nil
            && !InternalFileDrag.rejectsFolderDrop(hasMarker: info.hasItemsConforming(to: [InternalFileDrag.type.rawValue]))
    }
    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        store.setRailDragTarget("header", entered: true)
        store.openWorkspaceList(forDrag: true)
    }
    func dropExited(info: DropInfo) { store.setRailDragTarget("header", entered: false) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func performDrop(info: DropInfo) -> Bool { store.finishNavigationDrag(); return false }
}

extension WorkspaceStore {
    func setRailDragTarget(_ target: String, entered: Bool) {
        navigationDragExit?.cancel()
        if entered { navigationDragTargets.insert(target) }
        else { navigationDragTargets.remove(target) }
        guard navigationDragTargets.isEmpty, navigationPresentation.dragPeek else { return }
        navigationDragExit = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, self.navigationDragTargets.isEmpty else { return }
            self.closeNavigation()
        }
    }
    func finishNavigationDrag() {
        navigationDragExit?.cancel()
        navigationDragTargets = []
        if navigationPresentation.dragPeek { closeNavigation() }
    }
}
