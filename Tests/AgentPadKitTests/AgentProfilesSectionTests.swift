import Foundation
import XCTest
@testable import AgentPadKit

@MainActor
final class AgentProfilesSectionTests: XCTestCase {
    private func profile(_ name: String) -> AgentProfile {
        AgentProfile(id: UUID(), name: name, templateID: "codex", rosterID: "codex",
            folder: URL(fileURLWithPath: "/project"), launchOptions: "", createdAt: .now)
    }

    func testSharedOnlyHasNoPrivateHeader() {
        let shared = profile("Shared")
        for disconnected in [false, true] {
            let groups = AgentProfilesSection.groups([shared], sharedProfiles: [shared.id], disconnected: disconnected)
            XCTAssertEqual(groups.map(\.title), [disconnected ? "Shared with team · not connected" : "Shared with team"])
            XCTAssertEqual(groups.map(\.profiles), [[shared]])
        }
    }

    func testPrivateOnlyHasNoSharedHeader() {
        let local = profile("Private")
        let groups = AgentProfilesSection.groups([local], sharedProfiles: [UUID()])
        XCTAssertEqual(groups.map(\.title), ["Only you"])
        XCTAssertEqual(groups.map(\.profiles), [[local]])
    }

    func testMixedProfilesKeepGroupAndProfileOrder() {
        let first = profile("A"), shared = profile("B"), last = profile("C")
        let groups = AgentProfilesSection.groups([first, shared, last], sharedProfiles: [shared.id])
        XCTAssertEqual(groups.map(\.title), ["Shared with team", "Only you"])
        XCTAssertEqual(groups.map(\.profiles), [[shared], [first, last]])
    }

    func testNoProfilesLeavesNoGroupsAboveEmptyState() {
        XCTAssertTrue(AgentProfilesSection.groups([], sharedProfiles: []).isEmpty)
        XCTAssertTrue(AgentProfilesSection.groups([], sharedProfiles: [UUID()], disconnected: true).isEmpty)
    }
}
