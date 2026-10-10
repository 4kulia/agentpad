import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class AttentionIndicatorViewTests: XCTestCase {
    func testEveryMarkReservesTheSameSlotInBothThemes() {
        let marks: [AttentionIndicator?] = [nil] + AttentionIndicator.Kind.allCases.map {
            AttentionIndicator([.init(id: "reason", kind: $0, summary: $0.label)])
        }
        for scheme in [ColorScheme.light, .dark] {
            for mark in marks {
                let view = NSHostingView(rootView: AttentionIndicatorView(indicator: mark).environment(\.colorScheme, scheme))
                XCTAssertEqual(view.fittingSize, NSSize(width: 16, height: 16))
            }
        }
    }
}
