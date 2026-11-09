import CryptoKit
import Foundation
import ImageIO
import XCTest

final class ChatNativeReferenceManifestTests: XCTestCase {
    private struct CaptureMetadata: Decodable, Equatable {
        var captureID: String
        var theme: String
        var width: Int
    }

    private struct Expectations: Decodable {
        struct State: Decodable {
            var id: String
            var label: String
            var nonbitmap: Bool
            var captures: [String]
            var contract: String?
        }
        struct Gap: Decodable {
            var state: String
            var widths: [Int]
            var reason: String
            var status: String
        }
        var schemaVersion: Int
        var checklistSHA256: String
        var themes: [String]
        var widths: [Int]
        // Capture stems describe the requested viewport; popup content has its
        // own rendered width, recorded separately from inventory coverage.
        var renderedWidths: [String: Int]
        var captures: [String: Int]
        var states: [State]
        var gaps: [Gap]

        var requiredCaptures: [CaptureMetadata] {
            captures.keys.sorted().flatMap { stem in
                themes.map { CaptureMetadata(captureID: stem + "-" + $0, theme: $0, width: renderedWidths[stem] ?? captures[stem]!) }
            }
        }
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func reference() throws -> URL {
        guard let selected = ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_REFERENCE_VALIDATE"] else {
            throw XCTSkip("Frozen external reference validation is opt-in; set AGENTPAD_CHAT_NATIVE_REFERENCE_VALIDATE to an absolute evidence directory")
        }
        return try ChatTimelineReferencePaths.root(selected)
    }

    private func object(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], url.path)
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sourceArchiveIssues(_ source: [String: Any], root: URL) throws -> [String] {
        let archive = try XCTUnwrap(source["sourceArchive"] as? [String: Any])
        let path = try XCTUnwrap(archive["path"] as? String)
        let expected = try XCTUnwrap(archive["sha256"] as? String)
        return hash(try Data(contentsOf: root.appendingPathComponent(path))) == expected
            ? [] : ["Changed source archive \(path)"]
    }

    private func captureArtifactIssues(_ record: [String: Any], image: Data, sidecar: [String: Any]) throws -> [String] {
        let id = try XCTUnwrap(record["captureID"] as? String)
        let expected = try XCTUnwrap(record["sha256"] as? String)
        var issues: [String] = []
        if hash(image) != expected { issues.append("Changed capture \(id)") }
        if sidecar as NSDictionary != record as NSDictionary { issues.append("Changed sidecar \(id)") }
        return issues
    }

    private func expectations() throws -> Expectations {
        let path = repository.appendingPathComponent("Tests/AgentPadKitTests/Fixtures/chat-native-reference-expected.json")
        return try JSONDecoder().decode(Expectations.self, from: Data(contentsOf: path))
    }

    // The requirement fixture is frozen independently of captures.json. A valid
    // pair remaining in an otherwise truncated index must never establish coverage.
    private func captureIssues(_ records: [CaptureMetadata], expected: Expectations) -> [String] {
        var issues: [String] = []
        let required = Dictionary(expected.requiredCaptures.map { ($0.captureID, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        for record in records {
            if !seen.insert(record.captureID).inserted { issues.append("Duplicate capture \(record.captureID)") }
            guard let metadata = required[record.captureID] else {
                issues.append("Unexpected capture \(record.captureID)")
                continue
            }
            if record != metadata { issues.append("Incorrect theme or width for \(record.captureID)") }
        }
        issues += Set(required.keys).subtracting(seen).map { "Missing capture \($0)" }
        return issues.sorted()
    }

    private func expectationIssues(_ expected: Expectations) -> [String] {
        var issues: [String] = []
        if expected.schemaVersion != 1 { issues.append("Unsupported expectation schema") }
        if expected.themes != ["light", "dark"] { issues.append("Required themes must be light and dark") }
        if expected.widths != [760, 420] { issues.append("Required widths must be 760 and 420") }
        for (stem, width) in expected.renderedWidths where expected.captures[stem] == nil || width <= 0 {
            issues.append("Invalid rendered width \(stem)")
        }
        let stateIDs = Set(expected.states.map(\.id))
        if stateIDs.count != expected.states.count { issues.append("Duplicate inventory state") }
        var gapStates: Set<String> = []
        for gap in expected.gaps {
            if !gapStates.insert(gap.state).inserted { issues.append("Duplicate gap \(gap.state)") }
            if !stateIDs.contains(gap.state) { issues.append("Unknown gap state \(gap.state)") }
            if gap.widths.isEmpty || Set(gap.widths).count != gap.widths.count
                || !Set(gap.widths).isSubset(of: Set(expected.widths)) {
                issues.append("Invalid gap widths \(gap.state)")
            }
            if gap.reason.isEmpty || gap.status.isEmpty { issues.append("Unexplained gap \(gap.state)") }
        }
        for state in expected.states {
            if state.label.isEmpty { issues.append("Missing label \(state.id)") }
            if Set(state.captures).count != state.captures.count { issues.append("Duplicate state capture \(state.id)") }
            for stem in state.captures where expected.captures[stem] == nil {
                issues.append("Unknown capture \(stem) for \(state.id)")
            }
            let gaps = Set(expected.gaps.filter { $0.state == state.id }.flatMap(\.widths))
            if state.nonbitmap {
                if state.contract?.isEmpty != false { issues.append("Missing nonbitmap contract \(state.id)") }
                if !gaps.isEmpty || !state.captures.isEmpty { issues.append("Nonbitmap state has bitmap coverage \(state.id)") }
                continue
            }
            if state.contract != nil { issues.append("Bitmap state has nonbitmap contract \(state.id)") }
            let captureWidths = Set(state.captures.compactMap { expected.captures[$0] })
            // Each required stem expands to both themes, so each width must be
            // represented by those paired captures XOR one explicit gap.
            for width in expected.widths {
                if !captureWidths.contains(width) && !gaps.contains(width) {
                    issues.append("Unaccounted state \(state.id) at \(width)")
                }
                if captureWidths.contains(width) && gaps.contains(width) {
                    issues.append("Conflicting gap \(state.id) at \(width)")
                }
            }
        }
        return issues.sorted()
    }

    func testExpectedInventoryAccountsForEveryStateThemeAndWidth() throws {
        let expected = try expectations()
        XCTAssertEqual(expectationIssues(expected), [])
        XCTAssertEqual(expected.states.count, 531)
        XCTAssertEqual(expected.requiredCaptures.count, 1040)
        XCTAssertEqual(expected.states.filter(\.nonbitmap).count, 97)
        XCTAssertEqual(expected.gaps.count, 63, "23 presentation gaps plus 40 explicit width gaps")
        XCTAssertEqual(expected.states.filter { !$0.nonbitmap && $0.captures.isEmpty }.count, 23)
        XCTAssertEqual(captureIssues(expected.requiredCaptures, expected: expected), [])
    }

    func testCaptureCoverageRejectsOneMissingRecordAndAnEntireThemePair() throws {
        let expected = try expectations()
        let records = expected.requiredCaptures
        let id = "production-channel-offline-760-light"
        XCTAssertEqual(captureIssues(records.filter { $0.captureID != id }, expected: expected), ["Missing capture \(id)"])
        let pair = ["production-channel-offline-760-dark", id]
        XCTAssertEqual(captureIssues(records.filter { !pair.contains($0.captureID) }, expected: expected),
                       pair.map { "Missing capture \($0)" }.sorted())
        let decodedOnly = records.filter { $0.captureID.hasPrefix("image-decoded-760-") }
        XCTAssertEqual(decodedOnly.count, 2)
        XCTAssertEqual(captureIssues(decodedOnly, expected: expected),
                       records.filter { !decodedOnly.contains($0) }.map { "Missing capture \($0.captureID)" }.sorted())
    }

    func testCaptureCoverageRejectsDuplicatesUnexpectedIDsAndWrongMetadata() throws {
        let expected = try expectations()
        let records = expected.requiredCaptures
        let first = try XCTUnwrap(records.first)
        XCTAssertEqual(captureIssues(records + [first], expected: expected), ["Duplicate capture \(first.captureID)"])
        var extra = first
        extra.captureID = "unlisted-760-light"
        XCTAssertEqual(captureIssues(records + [extra], expected: expected), ["Unexpected capture \(extra.captureID)"])
        var wrongTheme = records
        wrongTheme[0].theme = "dark"
        var wrongWidth = records
        wrongWidth[0].width += 1
        for mutation in [wrongTheme, wrongWidth] {
            XCTAssertEqual(captureIssues(mutation, expected: expected), ["Incorrect theme or width for \(first.captureID)"])
        }
    }

    func testInventoryRejectsOmittedConflictingAndUnknownGaps() throws {
        var missing = try expectations()
        missing.gaps.removeAll { $0.state == "T08.01" }
        XCTAssertEqual(expectationIssues(missing), ["Unaccounted state T08.01 at 420"])
        var conflicting = try expectations()
        conflicting.gaps.append(.init(state: "T01.01", widths: [760], reason: "An existing capture cannot also be a gap", status: "gap"))
        XCTAssertEqual(expectationIssues(conflicting), ["Conflicting gap T01.01 at 760"])
        var unknown = try expectations()
        unknown.gaps.append(.init(state: "R99.01", widths: [760, 420], reason: "Outside the reviewed inventory", status: "gap"))
        XCTAssertEqual(expectationIssues(unknown), ["Unknown gap state R99.01"])
        var noContract = try expectations()
        let index = try XCTUnwrap(noContract.states.firstIndex { $0.id == "T02.02" })
        noContract.states[index].contract = nil
        XCTAssertEqual(expectationIssues(noContract), ["Missing nonbitmap contract T02.02"])
    }

    func testConfiguredEvidenceRootAcceptsAnAbsoluteDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relocated-reference")
        XCTAssertEqual(try ChatTimelineReferencePaths.configuredRoot(environment: [ChatTimelineReferencePaths.environmentKey: directory.path]),
                       directory.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertThrowsError(try ChatTimelineReferencePaths.configuredRoot(environment: [:]))
        XCTAssertThrowsError(try ChatTimelineReferencePaths.configuredRoot(environment: [ChatTimelineReferencePaths.environmentKey: "relative/reference"]))
    }

    func testFrozenSourceAllowsCandidateEditsButRejectsArchiveTampering() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("reference-integrity-\(UUID())", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let checkout = root.appendingPathComponent("candidate", isDirectory: true)
        let paths = ["Sources/AgentPadKit/Terminal/LibghosttyEngine.swift",
                     "Sources/AgentPadKit/AgentPad/Chat/ChatTimelineView.swift"]
        let frozen = Data("frozen source fixture".utf8)
        for path in paths {
            let file = checkout.appendingPathComponent(path)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try frozen.write(to: file)
        }
        // The integrity check treats the archived snapshot as opaque bytes.
        let archive = root.appendingPathComponent("source-baseline.snapshot")
        try frozen.write(to: archive)
        let source: [String: Any] = [
            "repository": checkout.path,
            "files": paths.map { ["path": $0, "sha256": hash(frozen)] },
            "sourceArchive": ["path": archive.lastPathComponent, "sha256": hash(frozen)],
        ]
        XCTAssertEqual(try sourceArchiveIssues(source, root: root), [])
        for path in paths {
            let file = checkout.appendingPathComponent(path)
            try Data("intentional candidate edit".utf8).write(to: file)
            XCTAssertNotEqual(hash(try Data(contentsOf: file)), hash(frozen))
            XCTAssertEqual(try sourceArchiveIssues(source, root: root), [], path)
            try manager.removeItem(at: file)
            XCTAssertEqual(try sourceArchiveIssues(source, root: root), [], "Removed candidate source: \(path)")
        }
        try Data("tampered archived snapshot".utf8).write(to: archive)
        XCTAssertEqual(try sourceArchiveIssues(source, root: root), ["Changed source archive source-baseline.snapshot"])
    }

    func testCaptureIntegrityRejectsImageAndSidecarTampering() throws {
        let image = Data("frozen capture fixture".utf8)
        let record: [String: Any] = ["captureID": "fixture-760-light", "sha256": hash(image), "width": 760, "theme": "light"]
        XCTAssertEqual(try captureArtifactIssues(record, image: image, sidecar: record), [])
        var tamperedImage = image
        tamperedImage.append(0)
        XCTAssertEqual(try captureArtifactIssues(record, image: tamperedImage, sidecar: record), ["Changed capture fixture-760-light"])
        var tamperedSidecar = record
        tamperedSidecar["width"] = 420
        XCTAssertEqual(try captureArtifactIssues(record, image: image, sidecar: tamperedSidecar), ["Changed sidecar fixture-760-light"])
    }

    @MainActor func testCaptureDestinationStaysInsideConfiguredRootAndCannotOverwrite() throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = temporary.appendingPathComponent("reference", isDirectory: true)
        let outside = temporary.appendingPathComponent("reference-sibling", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let output = root.appendingPathComponent("captures", isDirectory: true)
        let capture = try ChatTimelineReferenceCapture(output: output, me: "reference-user", evidenceRoot: root)
        XCTAssertEqual(capture.output, output)
        XCTAssertTrue(manager.fileExists(atPath: output.path))
        let traversing = URL(fileURLWithPath: root.path + "/../reference-sibling/captures")
        let link = root.appendingPathComponent("linked")
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        for destination in [outside.appendingPathComponent("captures"), traversing, link.appendingPathComponent("captures")] {
            XCTAssertThrowsError(try ChatTimelineReferenceCapture(output: destination, me: "reference-user", evidenceRoot: root), destination.path)
        }
        try capture.finish()
        let index = output.appendingPathComponent("captures.json")
        let frozen = try Data(contentsOf: index)
        XCTAssertThrowsError(try ChatTimelineReferenceCapture(output: output, me: "reference-user", evidenceRoot: root))
        XCTAssertEqual(try Data(contentsOf: index), frozen)
    }

    func testExpectedInventoryMatchesPinnedExternalChecklist() throws {
        let root = try reference()
        let expected = try expectations()
        let path = root.appendingPathComponent("visual-state-checklist.json")
        XCTAssertEqual(hash(try Data(contentsOf: path)), expected.checklistSHA256)
        let checklist = try object(path)
        let states = try XCTUnwrap(checklist["states"] as? [[String: Any]])
        var labels: [String: String] = [:]
        for state in states {
            let id = try XCTUnwrap(state["state_id"] as? String)
            XCTAssertNil(labels.updateValue(try XCTUnwrap(state["label"] as? String), forKey: id), "Duplicate checklist state \(id)")
            XCTAssertEqual(state["themes"] as? [String], expected.themes, id)
            XCTAssertEqual(state["widths"] as? [String: Int], ["feed": 760, "thread": 420], id)
        }
        let expectedLabels = Dictionary(expected.states.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(labels, expectedLabels, "Every inventory state ID and label must remain represented")
        XCTAssertEqual(checklist["state_count"] as? Int, expected.states.count)
    }

    func testFrozenSourceAndArchivedEvidenceRemainUnchanged() throws {
        let root = try reference()
        let source = try object(root.appendingPathComponent("source-manifest.json"))
        XCTAssertEqual(source["sourceSHA"] as? String, "b6a714b621fdcdefdda38052b86acfa2386e13a3")
        XCTAssertEqual(source["branch"] as? String, "t-attn")
        XCTAssertEqual(try sourceArchiveIssues(source, root: root), [])
        // Whole-repository hashes record the freeze's provenance. Compare the
        // archived snapshot, not live Sources/: native candidates intentionally
        // change the renderer while these reference artifacts stay immutable.
        let files = try XCTUnwrap(source["files"] as? [[String: Any]])
        let product = files.filter { ($0["path"] as? String)?.hasPrefix("Sources/") == true }
        XCTAssertFalse(product.isEmpty)
        let archive = try object(root.appendingPathComponent("archived-evidence.json"))
        let archived = try XCTUnwrap(archive["files"] as? [[String: Any]])
        XCTAssertFalse(archived.isEmpty)
        for entry in archived {
            let path = try XCTUnwrap(entry["path"] as? String)
            XCTAssertEqual(hash(try Data(contentsOf: URL(fileURLWithPath: path))), entry["sha256"] as? String, path)
        }
        let environment = try object(root.appendingPathComponent("environment-manifest.json"))
        XCTAssertEqual(environment["consoleLocked"] as? Bool, false)
        XCTAssertFalse(try XCTUnwrap(environment["fonts"] as? [[String: Any]]).isEmpty)
        let catalog = try object(root.appendingPathComponent("test-catalog.json"))
        let entries = try XCTUnwrap(catalog["entries"] as? [[String: Any]])
        let expected = [("T", 39), ("S", 26), ("R", 55)].flatMap { prefix, count in (1...count).map { String(format: "%@%02d", prefix, $0) } }
        XCTAssertEqual(entries.compactMap { $0["id"] as? String }.sorted(), expected.sorted())
        XCTAssertEqual(catalog["target_head"] as? String, source["sourceSHA"] as? String)
    }

    func testRecordedScrollEventsMatchEveryArchivedSignature() throws {
        let root = try reference()
        let fixture = try object(root.appendingPathComponent("fixture-manifest.json"))
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        let counts = ["channel": 480, "fixture-root": 480, "media-channel": 200, "media-fixture-root": 200]
        XCTAssertEqual(Set(cases.compactMap { $0["name"] as? String }), Set(counts.keys))
        let keys = ["kind", "requested", "phase", "segment"]
        var settings: NSDictionary?
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let recordedPath = try XCTUnwrap(item["referenceSamples"] as? String)
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(recordedPath))) as? [[String: Any]])
            let signatures = try raw.map { record in try keys.map { try XCTUnwrap(record[$0], "\(name): \($0)") } }
            XCTAssertEqual(signatures as NSArray, try XCTUnwrap(item["signatures"] as? NSArray), name)
            let moving = raw.filter { ["up", "down"].contains($0["kind"] as? String ?? "") }
            XCTAssertEqual(moving.count, counts[name], name)
            for record in moving {
                XCTAssertEqual(record["valid"] as? Bool, true, name)
                XCTAssertFalse(try XCTUnwrap(record["anchor"] as? String).isEmpty, name)
                for key in ["requested", "actual", "documentHeight", "anchorBefore", "anchorAfter", "error", "layoutError", "milliseconds", "threadCpuMilliseconds"] {
                    XCTAssertTrue(try XCTUnwrap(record[key] as? NSNumber, "\(name): \(key)").doubleValue.isFinite, name)
                }
            }
            let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("scroll/\(name)-fixture.json"))) as? [[String: Any]])
            XCTAssertFalse(values.isEmpty, name)
            XCTAssertEqual(Set(values.compactMap { $0["messageId"] as? String }).count, values.count, name)
            XCTAssertTrue(values.allSatisfy { $0["revision"] is NSNumber }, name)
            let current = try object(root.appendingPathComponent("scroll/\(name)-settings.json")) as NSDictionary
            if let settings { XCTAssertEqual(current, settings, name) }
            else { settings = current }
        }
        XCTAssertEqual(fixture["primaryMovingEvents"] as? Int, 1360)
    }

    func testReferenceCapturesContainPairedDecodedViewBitmaps() throws {
        let root = try reference()
        let folder = root.appendingPathComponent("captures")
        let index = try object(folder.appendingPathComponent("captures.json"))
        let captures = try XCTUnwrap(index["captures"] as? [[String: Any]])
        let expected = try expectations()
        XCTAssertEqual(expectationIssues(expected), [])
        let metadata = try JSONDecoder().decode([CaptureMetadata].self, from: JSONSerialization.data(withJSONObject: captures))
        XCTAssertEqual(captureIssues(metadata, expected: expected), [])
        var pairs: [String: Set<String>] = [:]
        var seen: Set<String> = []
        var decoded: Set<String> = []
        for record in captures {
            let id = try XCTUnwrap(record["captureID"] as? String)
            let theme = try XCTUnwrap(record["theme"] as? String)
            XCTAssertTrue(seen.insert(id).inserted, "Duplicate capture \(id)")
            XCTAssertTrue(["light", "dark"].contains(theme), id)
            XCTAssertTrue(id.hasSuffix("-" + theme), id)
            pairs[String(id.dropLast(theme.count + 1)), default: []].insert(theme)
            let image = try XCTUnwrap(record["image"] as? String)
            let data = try Data(contentsOf: folder.appendingPathComponent(image))
            let sidecar = try object(folder.appendingPathComponent(id + ".json"))
            XCTAssertEqual(try captureArtifactIssues(record, image: data, sidecar: sidecar), [], id)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), id)
            let bitmap = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), id)
            XCTAssertEqual(bitmap.width, record["pixelsWide"] as? Int, id)
            XCTAssertEqual(bitmap.height, record["pixelsHigh"] as? Int, id)
            XCTAssertGreaterThan(bitmap.width, 0, id)
            XCTAssertGreaterThan(bitmap.height, 0, id)
            let values = try JSONSerialization.data(withJSONObject: try XCTUnwrap(record["fixtureValues"]), options: [.sortedKeys])
            XCTAssertEqual(hash(values), record["fixtureSHA256"] as? String, id)
            let fonts = try XCTUnwrap(record["fonts"] as? [String: String])
            XCTAssertFalse(fonts.values.contains("MISSING"), id)
            if let pixels = record["decodedChartPixels"] as? Int, pixels >= 150 { decoded.insert(theme) }
        }
        for (id, themes) in pairs { XCTAssertEqual(themes, ["light", "dark"], id) }
        XCTAssertEqual(decoded, ["light", "dark"], "Each theme requires settled decoded image pixels")
    }
}
