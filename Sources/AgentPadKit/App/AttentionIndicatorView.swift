import SwiftUI

/// A fixed slot, with no animation or independent accessibility target.
struct AttentionIndicatorView: View {
    let indicator: AttentionIndicator?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    private var attention: Color { colorScheme == .light ? Self.lightAttention : Theme.activityAttention }
    private var failure: Color { colorScheme == .light ? Self.lightFailure : Theme.activityFailure }
    private var success: Color { colorScheme == .light ? Self.lightSuccess : Theme.activitySuccess }
    private var unread: Color { colorScheme == .light ? Self.lightUnread : Theme.activityRunning }
    private var glyph: Color { colorScheme == .light ? .white : .black }
    private static let lightAttention = Color(hex: "956017")!
    private static let lightFailure = Color(hex: "b33740")!
    private static let lightSuccess = Color(hex: "357c43")!
    private static let lightUnread = Color(hex: "2879a8")!

    var body: some View {
        ZStack {
            if let kind = indicator?.kind {
                switch kind {
                case .needsInput:
                    Circle().fill(attention)
                        .overlay(Text("!").font(.system(size: 10, weight: .heavy)).foregroundStyle(glyph))
                case .failed:
                    RoundedRectangle(cornerRadius: 3).fill(failure)
                        .overlay(Image(systemName: "xmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(glyph))
                case .finished:
                    Circle().strokeBorder(success, lineWidth: contrast == .increased ? 2 : 1.5)
                        .overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(success))
                case .unread:
                    Circle().fill(unread).frame(width: 7, height: 7)
                }
            }
        }.frame(width: 14, height: 14)
            .frame(width: 16, height: 16)
            .transaction { $0.animation = nil }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
