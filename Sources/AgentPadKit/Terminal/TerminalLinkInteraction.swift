import AppKit
import GhosttyKit

/// The core owns OSC 8 metadata and external links. AgentPad adds file ranges
/// on the same grid, including quoted paths and bare filenames. Inspecting
/// text never changes the selection or clipboard.
@MainActor
final class TerminalLinkInteraction {
    unowned let view: GhosttySurfaceView
    private var osc8Target: String?
    private var lastCell: NSPoint?
    private var hovered: Hit?
    private var pressed: Hit?
    private var pressPoint: NSPoint?
    private var dragged = false
    private let underline = CAShapeLayer()
    private var textURLPreview: String?
    private static var previewPolicy = "true"
    private static var foreground = NSColor.white.cgColor

    private struct Hit: Equatable {
        let link: TerminalTextLink
        let rects: [NSRect]
    }

    init(view: GhosttySurfaceView) { self.view = view }

    /// In this core mode MOUSE_OVER_LINK carries only exact OSC 8 targets:
    /// the public API's way to distinguish metadata from regex matches.
    static let coreConfig = "link-previews = osc8\n"

    static func configure(_ config: ghostty_config_t?) {
        var policy: UnsafePointer<CChar>?
        if ghostty_config_get(config, &policy, "link-previews", 13), let policy {
            previewPolicy = String(cString: policy)
        }
        var color = ghostty_config_color_s()
        if ghostty_config_get(config, &color, "foreground", 10) {
            foreground = NSColor(srgbRed: Double(color.r) / 255, green: Double(color.g) / 255,
                blue: Double(color.b) / 255, alpha: 1).cgColor
        }
        coreConfig.withCString { ghostty_config_load_string(config, $0, UInt(coreConfig.utf8.count), "agentpad-links") }
    }

    func receiveCoreHover(_ value: String?) { osc8Target = value }

    func prepareForScroll(_ event: NSEvent) {
        clear()
        guard let surface = view.surface else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        // clear() invalidates OSC 8's cell cache by reporting a mouse exit.
        // Mouse-reporting TUIs ignore scroll at that outside position. Restore
        // the event's actual cell, even if no mouseMoved preceded the gesture.
        ghostty_surface_mouse_pos(surface, point.x, view.bounds.height - point.y,
                                  GhosttySurfaceView.mapModifiers(event.modifierFlags))
    }

    func clear() {
        if pressed != nil { dragged = true }
        if hovered != nil { view.restoreNativeMouseCursor() }
        if let surface = view.surface {
            ghostty_surface_mouse_pos(surface, -1, -1, GhosttySurfaceView.mapModifiers([]))
        }
        hovered = nil
        textURLPreview = nil
        lastCell = nil
        osc8Target = nil
        underline.path = nil
        view.onLinkHover?(nil)
    }

    func move(to point: NSPoint, modifiers: NSEvent.ModifierFlags, force: Bool = false) {
        guard let surface = view.surface else { return }
        let command = modifiers.intersection([.command, .control, .option, .shift]) == .command
        var grid = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &grid), grid.cell_width > 0, grid.cell_height > 0 else { return }
        let column = Int(floor((point.x - grid.padding_left) / grid.cell_width))
        let row = Int(floor((view.bounds.height - point.y - grid.padding_top) / grid.cell_height))
        let cell = NSPoint(x: column, y: row)
        // mouse_pos can reuse the core's cell cache after an ordinary click
        // or changed OSC 8 metadata. Invalidate it at activation boundaries
        // and when Command first becomes active, before trusting the hint.
        if force || (command && lastCell == nil) {
            osc8Target = nil
            ghostty_surface_mouse_pos(surface, -1, -1, GhosttySurfaceView.mapModifiers([]))
        }
        if lastCell != cell || !command { osc8Target = nil }
        lastCell = command ? cell : nil
        ghostty_surface_mouse_pos(surface, point.x, view.bounds.height - point.y, GhosttySurfaceView.mapModifiers(modifiers))
        if let pressPoint, hypot(point.x - pressPoint.x, point.y - pressPoint.y) > 4 { dragged = true }
        let wasHovering = hovered != nil
        hovered = nil
        textURLPreview = nil
        if command, osc8Target == nil, column >= 0, row >= 0,
           column < grid.columns, row < grid.rows, grid.columns <= 1024 {
            hovered = hit(column: column, row: row, grid: grid)
        }
        draw(hovered?.rects ?? [])
        if hovered != nil { NSCursor.pointingHand.set() }
        else if wasHovering { view.restoreNativeMouseCursor() }
        let preview = osc8Target ?? (Self.previewPolicy == "true" ? hovered?.link.value ?? textURLPreview : nil)
        view.onLinkHover?(Self.previewPolicy == "false" ? nil : preview)
    }

    func mouseDown(_ event: NSEvent) -> Bool {
        let point = view.convert(event.locationInWindow, from: nil)
        move(to: point, modifiers: event.modifierFlags, force: true)
        guard let hovered else { return false }
        pressed = hovered
        pressPoint = point
        dragged = false
        return true
    }

    func mouseUp(_ event: NSEvent) -> Bool {
        guard let pressed else { return false }
        let point = view.convert(event.locationInWindow, from: nil)
        move(to: point, modifiers: .command, force: true)
        let activate = !dragged && hovered == pressed && osc8Target == nil
        self.pressed = nil
        pressPoint = nil
        if activate { view.open(target: pressed.link.value) }
        move(to: point, modifiers: event.modifierFlags)
        return true
    }

    var isHandlingClick: Bool { pressed != nil }

    private func hit(column: Int, row: Int, grid: ghostty_surface_grid_metrics_s) -> Hit? {
        // Bounded read around the pointer. Ghostty preserves hard newlines and
        // joins soft wraps. Prefix reads map UTF-16 ranges back to cells
        // without guessing wide/combining character widths.
        let firstRow = max(0, row - 2)
        let lastRow = min(Int(grid.rows) - 1, row + 2)
        let columns = Int(grid.columns)
        let cellCount = (lastRow - firstRow + 1) * columns
        func prefix(_ cell: Int) -> String {
            read(fromRow: firstRow, throughColumn: cell % columns, row: firstRow + cell / columns)
        }
        let text = prefix(cellCount - 1)
        let offset = prefix((row - firstRow) * columns + column).utf16.count - 1
        textURLPreview = TerminalTextLinkDetector.urlPreview(in: text, at: offset)
        guard let link = TerminalTextLinkDetector.link(in: text, at: offset) else { return nil }
        func cell(at character: Int) -> Int {
            var low = 0, high = cellCount - 1
            while low < high {
                let mid = (low + high) / 2
                if prefix(mid).utf16.count > character { high = mid } else { low = mid + 1 }
            }
            return low
        }
        let first = cell(at: link.range.location)
        let last = cell(at: NSMaxRange(link.range) - 1)
        var rects: [NSRect] = []
        for relativeRow in (first / columns)...(last / columns) {
            let left = relativeRow == first / columns ? first % columns : 0
            let right = relativeRow == last / columns ? last % columns : columns - 1
            rects.append(NSRect(
                x: grid.padding_left + Double(left) * grid.cell_width,
                y: view.bounds.height - grid.padding_top - Double(firstRow + relativeRow + 1) * grid.cell_height + 2,
                width: Double(right - left + 1) * grid.cell_width, height: 1))
        }
        return Hit(link: link, rects: rects)
    }

    private func read(fromRow: Int, throughColumn: Int, row: Int) -> String {
        guard let surface = view.surface else { return "" }
        let selection = ghostty_selection_s(
            top_left: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(fromRow)),
            bottom_right: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(throughColumn), y: UInt32(row)),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    private func draw(_ rects: [NSRect]) {
        if underline.superlayer == nil { view.layer?.addSublayer(underline) }
        let path = CGMutablePath()
        rects.forEach { path.addRect($0) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        underline.fillColor = Self.foreground
        underline.zPosition = 10
        underline.path = path
        CATransaction.commit()
    }
}
