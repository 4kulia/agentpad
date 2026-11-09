import AppKit
import SwiftUI

// Opt-in, observation-only geometry markers. Background views consume the
// rendered SwiftUI size; they never propose a size or run the native calculator.
private struct ChatParityEnabledKey: EnvironmentKey { static let defaultValue = false }
private struct ChatParityMessageKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var chatParityEnabled: Bool {
        get { self[ChatParityEnabledKey.self] }
        set { self[ChatParityEnabledKey.self] = newValue }
    }
    var chatParityMessage: String {
        get { self[ChatParityMessageKey.self] }
        set { self[ChatParityMessageKey.self] = newValue }
    }
}

#if DEBUG
@MainActor final class ChatTimelineParityProbeView: NSView {
    var semanticID = ""
    var role = ""
    var text: String?
    var colors: [String: NSColor] = [:]
    var srgbTokens: [String: UInt32] = [:]
    var opacity: Double = 1
    var lineBreaks: [NSRange]?
    var font: NSFont?
    var textBounds: [CGRect] = []
    // Raw SwiftUI coordinates, used only to reconcile capture inventories.
    var swiftUIGlobalFrame: CGRect = .null
    var renderTextInk: (() -> CGImage?)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct ChatParityMarker: NSViewRepresentable {
    let id: String
    let role: String
    let text: String?
    let colors: [String: Color]
    let srgbTokens: [String: UInt32]
    let opacity: Double
    let lineBreaks: [NSRange]?
    let font: NSFont?
    let textBounds: [CGRect]
    let swiftUIGlobalFrame: CGRect
    let renderTextInk: (() -> CGImage?)?
    func makeNSView(context: Context) -> ChatTimelineParityProbeView { ChatTimelineParityProbeView() }
    func updateNSView(_ view: ChatTimelineParityProbeView, context: Context) {
        view.semanticID = id; view.role = role; view.text = text
        view.colors = colors.mapValues { NSColor($0) }; view.opacity = opacity
        view.srgbTokens = srgbTokens
        view.lineBreaks = lineBreaks
        view.font = font; view.textBounds = textBounds
        view.swiftUIGlobalFrame = swiftUIGlobalFrame
        view.renderTextInk = renderTextInk
    }
}

private struct ChatParityModifier: ViewModifier {
    @Environment(\.chatParityEnabled) private var enabled
    @Environment(\.self) private var environment
    let id: String
    let role: String
    let text: String?
    let colors: [String: Color]
    let srgbTokens: [String: UInt32]
    let opacity: Double
    let font: Font?
    func body(content: Content) -> some View {
        content.backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
            if enabled && !id.isEmpty {
                GeometryReader { geometry in
                    ChatParityMarker(id: id, role: role, text: text, colors: colors, srgbTokens: srgbTokens, opacity: opacity,
                        lineBreaks: lineBreaks(layouts), font: resolvedFont,
                        textBounds: layouts.flatMap { anchored in
                            let origin = geometry[anchored.origin]
                            return anchored.layout.flatMap { line in
                                line.map { $0.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y) }
                            }
                        }, swiftUIGlobalFrame: geometry.frame(in: .global),
                        renderTextInk: inkRenderer(layouts, geometry: geometry))
                }
            }
        }
    }
    private var resolvedFont: NSFont? {
        guard text != nil else { return nil }
        if #available(macOS 26, *) {
            return (font ?? environment.font ?? .body).resolve(in: environment.fontResolutionContext).ctFont as NSFont
        }
        // A capture on an older OS fails closed instead of guessing a font.
        return nil
    }
    private func inkRenderer(_ layouts: [Text.LayoutKey.AnchoredLayout], geometry: GeometryProxy) -> (() -> CGImage?)? {
        guard text != nil, !layouts.isEmpty else { return nil }
        let runs = layouts.map { ($0.layout, geometry[$0.origin]) }
        let size = geometry.size, scale = environment.displayScale
        return {
            // Repaint the observed Text.Layout, without backgrounds, borders or
            // layout proposals. This is a coverage mask, never a replacement
            // reference image or a mask inferred from differing pixels.
            let canvas = Canvas { context, _ in
                for (layout, origin) in runs {
                    var drawing = context
                    drawing.translateBy(x: origin.x, y: origin.y)
                    for line in layout { drawing.draw(line) }
                }
            }.frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: canvas)
            renderer.scale = scale
            return renderer.cgImage
        }
    }
    private func lineBreaks(_ layouts: [Text.LayoutKey.AnchoredLayout]) -> [NSRange]? {
        guard let text else { return nil }
        let lines = layouts.flatMap { Array($0.layout) }
        let indices = lines.flatMap { $0.flatMap(\.characterIndices) }
        guard let origin = indices.min() else { return nil }
        let starts = lines.compactMap { $0.flatMap(\.characterIndices).min() }.map { origin.distance(to: $0) }
        let length = (text as NSString).length
        return starts.enumerated().map { index, start in
            NSRange(location: start, length: (index + 1 < starts.count ? starts[index + 1] : length) - start)
        }
    }
}
#endif

extension View {
    /// W09 observation is compiled only into an explicitly requested quiet
    /// capture build. Ordinary Debug and Release builds return the exact input
    /// view type, without evaluating probe arguments or installing observers.
    #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
    @ViewBuilder
    func chatReviewParity(_ id: @autoclosure () -> String, text: @autoclosure () -> String,
                          colors: @autoclosure () -> [String: Color] = [:],
                          font: @autoclosure () -> Font? = nil) -> some View {
        if ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_W09_CAPTURE"] == "1" {
            chatParity("w09/" + id(), "text", text: text(), colors: colors(), font: font())
        } else {
            self
        }
    }
    #else
    @inline(__always)
    func chatReviewParity(_ id: @autoclosure () -> String, text: @autoclosure () -> String,
                          colors: @autoclosure () -> [String: Color] = [:],
                          font: @autoclosure () -> Font? = nil) -> Self {
        self
    }
    #endif

    /// W07 opts into the same observation-only backgrounds as the earlier
    /// parity suites. The ordinary legacy render tree receives no marker.
    func chatMetadataParity(_ id: String, _ role: String, text: String? = nil,
                            colors: [String: Color] = [:], font: Font? = nil) -> some View {
        #if DEBUG
        chatParity(ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_W07_CAPTURE"] == "1" ? "w07/" + id : "",
                   role, text: text, colors: colors, font: font)
        #else
        self
        #endif
    }

    func chatParity(_ id: String, _ role: String, text: String? = nil,
                    colors: [String: Color] = [:], srgbTokens: [String: UInt32] = [:], opacity: Double = 1,
                    font: Font? = nil) -> some View {
        #if DEBUG
        modifier(ChatParityModifier(id: id, role: role, text: text, colors: colors, srgbTokens: srgbTokens, opacity: opacity, font: font))
        #else
        self
        #endif
    }
}
