import XCTest
@testable import AgentPadKit

final class VersionTests: XCTestCase {
    func testStripLeadingV() {
        XCTAssertEqual(Version.stripLeadingV("v0.12.0"), "0.12.0")
        XCTAssertEqual(Version.stripLeadingV("0.12.0"), "0.12.0")
        XCTAssertEqual(Version.stripLeadingV(""), "")
    }

    func testCompareOrders() {
        XCTAssertEqual(Version.compare("0.12.0", "0.12.0"), .orderedSame)
        XCTAssertEqual(Version.compare("0.12.0", "0.12.1"), .orderedAscending)
        XCTAssertEqual(Version.compare("0.12.1", "0.12.0"), .orderedDescending)
        XCTAssertEqual(Version.compare("0.9.0", "0.12.0"), .orderedAscending)
        XCTAssertEqual(Version.compare("1.0.0", "0.99.99"), .orderedDescending)
    }

    func testCompareHandlesDifferentSegmentCounts() {
        // Equal numeric segments fall back to localizedStandardCompare,
        // which sorts shorter strings before longer when the prefix matches.
        XCTAssertEqual(Version.compare("1.0", "1.0.0"), .orderedAscending)
        XCTAssertEqual(Version.compare("1.0", "1.0.1"), .orderedAscending)
        XCTAssertEqual(Version.compare("1.0.1", "1.0"), .orderedDescending)
    }

}
