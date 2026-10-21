import AppKit
import XCTest
@testable import AgentPadKit

final class SettingsSectionIconTests: XCTestCase {
    func testEverySectionHasItsOwnAvailableNativeSymbol() {
        let sections = SettingsTabSection.allCases
        XCTAssertEqual(sections.map(\.systemImage), [
            "gearshape", "person", "paperplane", "sidebar.left", "circle.lefthalf.filled",
            "cpu", "key", "terminal", "arrow.up.right.square", "rectangle.bottomthird.inset.filled",
            "bell", "magnifyingglass", "slider.horizontal.3", "info.circle", "square.and.arrow.down"
        ])
        XCTAssertEqual(Set(sections.map(\.systemImage)).count, sections.count)
        for section in sections {
            XCTAssertNotNil(NSImage(systemSymbolName: section.systemImage, accessibilityDescription: nil), section.title)
        }
    }
}
