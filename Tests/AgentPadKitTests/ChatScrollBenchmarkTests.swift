import AppKit
import AgentPadQuietTestSupport
import XCTest
@testable import AgentPadKit

@MainActor final class ChatScrollBenchmarkTests: XCTestCase {
    func testFreshProcessMount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-bench-mount-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ChatScrollFixture(root: nil, directory: directory)
        let adapter = ChatScrollMounts.benchmark ?? ChatScrollNativeAdapter()
        ChatScrollAppKitSettings.install()
        let before = Self.residentBytes()
        let start = CACurrentMediaTime()
        let mounted = try ChatScrollMounted(model: model, root: nil, adapter: adapter)
        let elapsed = (CACurrentMediaTime() - start) * 1000
        let after = Self.residentBytes()
        defer { mounted.close() }
        XCTAssertGreaterThan(before, 0)
        XCTAssertGreaterThan(after, 0)
        try ChatScrollRecords.writeDiagnostic([
            "renderer": adapter.name, "firstOpenMS": elapsed, "rssBefore": before, "rssAfterOpen": after,
            "width": mounted.host.bounds.width, "height": mounted.host.bounds.height,
            "scale": mounted.window.backingScaleFactor, "locale": Locale.current.identifier,
            "timeZone": TimeZone.current.identifier, "appKitSettings": ChatScrollAppKitSettings.snapshot(mounted.scroll)
        ], name: "mount", renderer: adapter.name)
        try mounted.recordDiagnostics("mount-counters")
        XCTAssertNil(APQuietFailure())
        XCTAssertFalse(APQuietWindowHasOSFocus(mounted.window))
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let code = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return code == KERN_SUCCESS ? info.resident_size : 0
    }
}

extension ChatScrollMounted {
    func recordDiagnostics(_ name: String) throws {
        var result: [String: Any] = ["renderer": adapter.name]
        if let view = Self.descendants(host, NativeChatTimelineContainer.self).first {
            let coordinator = view.coordinator, layout = coordinator.layoutEngine
            result.merge(["cellsCreated": coordinator.cellsCreated, "cellsReused": coordinator.cellsReused,
                "heightEntries": layout.heights.count, "heightBytes": layout.heights.cost,
                "contentEntries": layout.contents.count, "contentBytes": layout.contents.cost,
                "fullReloads": coordinator.fullReloads]) { _, new in new }
            XCTAssertLessThanOrEqual(layout.heights.count, 512)
            XCTAssertLessThanOrEqual(layout.contents.count, 512)
            XCTAssertLessThanOrEqual(layout.heights.cost, 256 * 1_024)
            XCTAssertLessThanOrEqual(layout.contents.cost, 4 * 1_024 * 1_024)
            if !probe.samples.isEmpty { XCTAssertGreaterThan(coordinator.cellsReused, 0) }
        }
        try ChatScrollRecords.writeDiagnostic(result, name: name, renderer: adapter.name)
    }
}
