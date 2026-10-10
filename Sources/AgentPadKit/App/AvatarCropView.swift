import SwiftUI

/// Shared square crop for local agents and server account photos.
struct AvatarCropView: View {
    let source: CGImage
    @Binding var crop: AvatarCrop
    let stableID: String
    let name: String
    let kind: AvatarPlaceholder.Kind
    var disabled = false
    let choose: () -> Void
    @State private var dragStart: AvatarCrop?
    var body: some View {
        let rect = crop.rect(width: source.width, height: source.height)
        let scale = 260 / rect.width
        return VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Drag to position · Arrow keys to nudge").font(Theme.display(12)); Spacer(); Button("Choose another…", action: choose) }
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 12) {
                    Image(decorative: source, scale: 1).resizable()
                        .frame(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
                        .offset(x: (CGFloat(source.width) / 2 - rect.midX) * scale, y: (CGFloat(source.height) / 2 - rect.midY) * scale)
                        .frame(width: 260, height: 260).clipped()
                        .overlay(RoundedRectangle(cornerRadius: kind == .person ? 130 : 20).strokeBorder(.white.opacity(0.7), lineWidth: 2))
                        .contentShape(Rectangle()).focusable().chatFocusRing()
                        .accessibilityLabel("Square avatar crop. Arrow keys move the image.")
                        .gesture(DragGesture().onChanged { value in
                            if dragStart == nil { dragStart = crop }
                            guard let start = dragStart else { return }
                            crop.x = min(1, max(0, start.x - value.translation.width / max(1, CGFloat(source.width) * scale - 260)))
                            crop.y = min(1, max(0, start.y - value.translation.height / max(1, CGFloat(source.height) * scale - 260)))
                        }.onEnded { _ in dragStart = nil })
                        .onMoveCommand { direction in
                            switch direction {
                            case .left: crop.x = min(1, crop.x + 0.02)
                            case .right: crop.x = max(0, crop.x - 0.02)
                            case .up: crop.y = min(1, crop.y + 0.02)
                            case .down: crop.y = max(0, crop.y - 0.02)
                            @unknown default: break
                            }
                        }
                    Slider(value: $crop.zoom, in: 1...3).accessibilityLabel("Zoom image").frame(width: 260)
                }
                if let preview = source.cropping(to: rect) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Preview").font(Theme.display(12, weight: .semibold))
                        ContactAvatar(stableID: stableID, name: name, kind: kind, size: 88,
                                      image: NSImage(cgImage: preview, size: .zero))
                    }
                }
            }
        }.disabled(disabled)
    }

}
