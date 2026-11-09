import Foundation
import XCTest
@testable import AgentPadKit

struct ChatScrollEvent: Equatable {
    var requested: Int32
    var phase: Int64
    var decaying = false
    var precise = true

    var signature: [String: Any] {
        ["kind": requested == 0 ? "phase-end" : (requested < 0 ? "up" : "down"),
         "requested": requested, "phase": phase,
         "segment": precise ? (decaying ? "decaying-precise" : "precise") : "wheel"]
    }
}

enum ChatScrollWorkload: CaseIterable {
    case mixed, media

    var movingCount: Int { self == .mixed ? 480 : 200 }

    func caseName(root: String?) -> String {
        (self == .media ? "media-" : "") + (root ?? "channel")
    }

    func events(direction: Int32) -> [ChatScrollEvent] {
        let count = self == .mixed ? 240 : 100
        var result: [ChatScrollEvent] = []
        for index in 0..<count {
            if self == .mixed && index == 200 { result.append(.init(requested: 0, phase: 4)) }
            let magnitude: Int32 = index < 200 ? [2, 4, 8, 12, 16, 12, 8, 4][index % 8] : max(1, 16 - Int32((index - 200) / 2))
            result.append(.init(requested: direction * magnitude,
                phase: index == 0 || index == 200 ? 1 : 2, decaying: index >= 200))
        }
        result.append(.init(requested: 0, phase: 4, decaying: self == .mixed))
        return result
    }

    var signatures: [[String: Any]] {
        [-1, 1].flatMap { events(direction: $0).map(\.signature) }
    }
}

enum ChatScrollRecords {
    static let jumpTolerance = 0.75

    static func validate(_ samples: [[String: Any]], workload: ChatScrollWorkload,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let keys = ["kind", "requested", "phase", "segment"]
        let signatures = samples.map { sample in sample.filter { keys.contains($0.key) } }
        XCTAssertEqual(signatures as NSArray, workload.signatures as NSArray, file: file, line: line)
        let moving = samples.filter { ($0["requested"] as? NSNumber)?.int32Value != 0 }
        XCTAssertEqual(moving.count, workload.movingCount, file: file, line: line)
        for sample in moving {
            XCTAssertEqual(sample["valid"] as? Bool, true, file: file, line: line)
            XCTAssertFalse(try XCTUnwrap(sample["anchor"] as? String, file: file, line: line).isEmpty, file: file, line: line)
            for key in ["requested", "actual", "documentHeight", "milliseconds", "threadCpuMilliseconds", "anchorBefore", "anchorAfter", "error", "layoutError"] {
                let value = try XCTUnwrap(sample[key] as? NSNumber, "Missing numeric \(key)", file: file, line: line)
                XCTAssertTrue(value.doubleValue.isFinite, "Nonfinite \(key)", file: file, line: line)
            }
        }
    }

    static func percentile95(_ costs: [Double]) -> Double {
        guard !costs.isEmpty else { return .nan }
        let ordered = costs.sorted()
        return ordered[Int(Double(ordered.count - 1) * 0.95)]
    }

    private static func directory(_ output: String, renderer: String?) -> URL {
        let root = URL(fileURLWithPath: output)
        if ProcessInfo.processInfo.environment["AGENTPAD_CHAT_BENCH_RENDERER"] != nil, let renderer {
            return root.appendingPathComponent(renderer)
        }
        return renderer == "native-product" ? root.appendingPathComponent("native-product") : root
    }

    static func write(_ samples: [[String: Any]], workload: ChatScrollWorkload, root: String?, renderer: String? = nil, prefix: String = "") throws {
        guard let output = ProcessInfo.processInfo.environment["AGENTPAD_SCROLL_EVIDENCE"] else { return }
        let url = directory(output, renderer: renderer).appendingPathComponent(prefix + workload.caseName(root: root) + ".json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .withoutOverwriting)
    }

    static func writeFixture(_ messages: [ChatMessage], workload: ChatScrollWorkload, root: String?, settings: [String: Any], renderer: String? = nil, prefix: String = "") throws {
        guard let output = ProcessInfo.processInfo.environment["AGENTPAD_SCROLL_EVIDENCE"] else { return }
        let directory = directory(output, renderer: renderer)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = prefix + workload.caseName(root: root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(messages).write(to: directory.appendingPathComponent(name + "-fixture.json"), options: .withoutOverwriting)
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name + "-settings.json"), options: .withoutOverwriting)
    }

    static func writeDiagnostic(_ value: [String: Any], name: String, renderer: String) throws {
        guard let output = ProcessInfo.processInfo.environment["AGENTPAD_SCROLL_EVIDENCE"] else { return }
        let root = directory(output, renderer: renderer)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
    }
}
