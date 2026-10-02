import AppKit

/// Shared geometry for AgentPad's floating utility panels. AppKit owns the
/// actual NSPanel placement; this helper keeps the coordinate calculation
/// pure so narrow windows and multi-display edges are testable without
/// constructing a window.
enum PanelPlacement {
    static let screenMargin: CGFloat = 8

    static func clampedOrigin(
        preferred: NSPoint,
        panelSize: NSSize,
        visibleFrame: NSRect,
        margin: CGFloat = screenMargin
    ) -> NSPoint {
        let safeFrame = visibleFrame.insetBy(dx: margin, dy: margin)
        return NSPoint(
            x: clampedCoordinate(
                preferred.x,
                length: panelSize.width,
                minimum: safeFrame.minX,
                maximum: safeFrame.maxX
            ),
            y: clampedCoordinate(
                preferred.y,
                length: panelSize.height,
                minimum: safeFrame.minY,
                maximum: safeFrame.maxY
            )
        )
    }

    private static func clampedCoordinate(
        _ value: CGFloat,
        length: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let latestOrigin = maximum - length
        guard latestOrigin >= minimum else { return minimum }
        return min(max(value, minimum), latestOrigin)
    }
}
