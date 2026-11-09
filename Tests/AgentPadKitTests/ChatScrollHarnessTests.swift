import AppKit
import AgentPadQuietTestSupport
import CryptoKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor final class ChatScrollHarnessTests: XCTestCase {
    private final class RecordingAdapter: ChatScrollMountAdapter {
        let reference = ChatScrollNativeAdapter()
        let name = "recording-native"
        var timelineCalls = 0
        var viewportCalls = 0
        var ownershipCalls = 0
        var acceptsOwnership = true

        func timeline(model: any ChatConversationPresentation, root: String?, probe: ChatScrollProbe) -> AnyView {
            timelineCalls += 1
            return reference.timeline(model: model, root: root, probe: probe)
        }

        func viewport(in host: NSView, probe: ChatScrollProbe) throws -> any ChatScrollControlling {
            viewportCalls += 1
            return try reference.viewport(in: host, probe: probe)
        }

        func belongs(_ view: NSTextView, to messageID: String, probe: ChatScrollProbe) -> Bool {
            ownershipCalls += 1
            return acceptsOwnership
        }
    }

    func testWorkloadSignaturesMatchArchivedPrimaryRecords() throws {
        let expected = [
            "channel": "c4d58914210fe0511d70bf6aa39b2d2f2a8b3679c6299bab197ca524dac44764",
            "fixture-root": "c4d58914210fe0511d70bf6aa39b2d2f2a8b3679c6299bab197ca524dac44764",
            "media-channel": "084d1acd4fc1573048fa5b39259a3f371f099a1fe125c3008167da7dec2f633f",
            "media-fixture-root": "084d1acd4fc1573048fa5b39259a3f371f099a1fe125c3008167da7dec2f633f"
        ]
        var actual: [String: String] = [:]
        var counts: [String: Int] = [:]
        var records: [String: Int] = [:]
        for workload in ChatScrollWorkload.allCases {
            for root: String? in [nil, "fixture-root"] {
                let name = workload.caseName(root: root)
                let data = try JSONSerialization.data(withJSONObject: workload.signatures, options: [.sortedKeys])
                actual[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                counts[name] = workload.events(direction: -1).filter { $0.requested != 0 }.count * 2
                records[name] = workload.signatures.count
            }
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(counts, ["channel": 480, "fixture-root": 480, "media-channel": 200, "media-fixture-root": 200])
        XCTAssertEqual(records, ["channel": 484, "fixture-root": 484, "media-channel": 202, "media-fixture-root": 202])
        XCTAssertEqual(counts.values.reduce(0, +), 1360)
        XCTAssertEqual(ChatScrollRecords.percentile95([100, 0, 9, 2, 8, 3, 7, 4, 6, 5, 1]), 9)
        XCTAssertEqual(ChatScrollRecords.jumpTolerance, 0.75)
    }

    func testNativeProductMountAndEventRecordUseAdapterBoundary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-scroll-harness-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(ChatScrollNativeAdapter().name, "native-product")
        for root: String? in [nil, "fixture-root"] {
            let adapter = RecordingAdapter()
            let mounted = try ChatScrollMounted(model: ChatScrollFixture(root: root, directory: directory), root: root, adapter: adapter)
            defer { mounted.close() }
            XCTAssertEqual(adapter.timelineCalls, 1)
            XCTAssertEqual(adapter.viewportCalls, 1)
            XCTAssertEqual(mounted.host.bounds.size, NSSize(width: root == nil ? 760 : 420, height: 600))
            XCTAssertEqual(mounted.model.feed.messages.count, 320)
            XCTAssertEqual(mounted.model.feed.messages.first?.id, "fixture-40")
            XCTAssertEqual(mounted.model.feed.messages.last?.id, "fixture-359")
            XCTAssertEqual(mounted.model.feed.unreadID, "fixture-190")
            mounted.viewport.stopFollowing()
            mounted.scroll.contentView.scroll(to: NSPoint(x: 0, y: mounted.scroll.contentView.bounds.minY - 1800))
            mounted.settle()
            try mounted.event(-2, phase: 1)
            let record = try XCTUnwrap(mounted.probe.samples.last)
            let numericKeys = ["requested", "actual", "documentHeight", "milliseconds", "threadCpuMilliseconds", "anchorBefore", "anchorAfter", "error", "layoutError"]
            XCTAssertEqual(Set(record.keys), Set(numericKeys + ["kind", "anchor", "valid", "heights", "phase", "segment", "nativePhase", "nativeMomentum"]))
            for key in numericKeys {
                XCTAssertTrue(try XCTUnwrap(record[key] as? NSNumber, key).doubleValue.isFinite, key)
            }
            XCTAssertEqual(record.filter { ["kind", "requested", "phase", "segment", "valid", "nativePhase", "nativeMomentum"].contains($0.key) } as NSDictionary,
                ["kind": "up", "requested": -2, "phase": 1, "segment": "precise", "valid": true, "nativePhase": 1, "nativeMomentum": 0] as NSDictionary)
            XCTAssertFalse(try XCTUnwrap(record["anchor"] as? String).isEmpty)
            XCTAssertGreaterThan(adapter.ownershipCalls, 0)
            let ownershipCalls = adapter.ownershipCalls
            adapter.acceptsOwnership = false
            try mounted.event(-2, phase: 2)
            let rejected = try XCTUnwrap(mounted.probe.samples.last)
            XCTAssertGreaterThan(adapter.ownershipCalls, ownershipCalls)
            XCTAssertEqual(Set(rejected.keys), Set(["kind", "requested", "actual", "anchor", "valid", "heights", "documentHeight", "milliseconds", "threadCpuMilliseconds", "phase", "segment", "nativePhase", "nativeMomentum"]))
            XCTAssertEqual(rejected.filter { ["kind", "requested", "phase", "segment", "valid", "anchor"].contains($0.key) } as NSDictionary,
                ["kind": "up", "requested": -2, "phase": 2, "segment": "precise", "valid": false, "anchor": ""] as NSDictionary)
            XCTAssertNil(APQuietFailure())
            XCTAssertFalse(APQuietWindowHasOSFocus(mounted.window))
        }
    }
}
