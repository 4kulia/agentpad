import AppKit
import XCTest

final class ChatTimelineParityTests: XCTestCase {
    private typealias Raster = ChatTimelineParity.Raster

    private func image(_ pixels: [[UInt8]]) -> Raster {
        Raster(width: pixels.count, height: 1, rgba: pixels.flatMap { $0 })
    }

    func testIdenticalAndOnePixelNeighbourhoodPassInBothDirections() {
        let white: [UInt8] = [255, 255, 255, 255], edge: [UInt8] = [50, 80, 110, 255]
        let current = image([white, edge, white, white])
        let candidate = image([white, white, [52, 78, 112, 255], white])
        XCTAssertEqual(ChatTimelineParity.bitmap(current, current).differentPixels, 0)
        for (a, b) in [(current, candidate), (candidate, current)] {
            let result = ChatTimelineParity.bitmap(a, b)
            XCTAssertEqual(result.differentPixels, 2)
            XCTAssertTrue(result.passes)
            XCTAssertEqual(result.unmatchedCurrentPixels, 0)
            XCTAssertEqual(result.unmatchedCandidatePixels, 0)
        }
    }

    func testOneUnmatchedPixelFailsWithoutAnyCountBudget() {
        let white: [UInt8] = [255, 255, 255, 255], edge: [UInt8] = [50, 80, 110, 255]
        let current = image([white, edge, white, white, white])
        let failures = [
            image([white, white, white, edge, white]), // outside the one-pixel neighbourhood
            image([white, [53, 80, 110, 255], white, white, white]), // R exceeds delta 2
            image([white, [50, 83, 110, 255], white, white, white]), // G exceeds delta 2
            image([white, [50, 80, 113, 255], white, white, white]), // B exceeds delta 2
            image([white, [50, 80, 110, 254], white, white, white]), // alpha is exact
            image([white, white, white, white, white]), // missing element
            image([white, edge, white, [5, 6, 7, 255], white]) // extra element
        ]
        for candidate in failures {
            XCTAssertFalse(ChatTimelineParity.bitmap(current, candidate).passes)
            XCTAssertFalse(ChatTimelineParity.bitmap(candidate, current).passes)
        }
        let extra = try! XCTUnwrap(failures.last)
        XCTAssertEqual(ChatTimelineParity.bitmap(current, extra).unmatchedCurrentPixels, 0)
        XCTAssertEqual(ChatTimelineParity.bitmap(current, extra).unmatchedCandidatePixels, 1,
                       "A one-way search would incorrectly accept the extra element")
    }

    func testDiagonalNeighbourAndImageEdgesDoNotWrapRows() {
        let white: [UInt8] = [255, 255, 255, 255], black: [UInt8] = [0, 0, 0, 255]
        let first = Raster(width: 3, height: 3, rgba: ([black] + Array(repeating: white, count: 8)).flatMap { $0 })
        let diagonal = Raster(width: 3, height: 3, rgba: (Array(repeating: white, count: 4) + [black] + Array(repeating: white, count: 4)).flatMap { $0 })
        XCTAssertTrue(ChatTimelineParity.bitmap(first, diagonal).passes)
        let wrapped = Raster(width: 3, height: 3, rgba: ([white, white, black] + Array(repeating: white, count: 6)).flatMap { $0 })
        XCTAssertFalse(ChatTimelineParity.bitmap(first, wrapped).passes)
        XCTAssertFalse(ChatTimelineParity.bitmap(first, image([black])).passes)
    }

    func testExactLayoutIsRequiredEvenWhenEveryBitmapPixelMatches() {
        let raster = image([[1, 2, 3, 255]])
        XCTAssertTrue(ChatTimelineParity.compare(currentLayout: [CGRect(x: 0, y: 0, width: 10, height: 20)],
            candidateLayout: [CGRect(x: 0, y: 0, width: 10, height: 20)], current: raster, candidate: raster).passes)
        XCTAssertFalse(ChatTimelineParity.compare(currentLayout: [CGRect(x: 0, y: 0, width: 10, height: 20)],
            candidateLayout: [CGRect(x: 1, y: 0, width: 10, height: 20)], current: raster, candidate: raster).passes)
    }

    @MainActor func testPerRunTranslationRejectsWeightSizeColourAndWholePixelChanges() throws {
        typealias M = ChatTimelineParityMetadata
        let width = 32, height = 18
        var bytes = Array(repeating: UInt8(255), count: width * height * 4)
        for y in 4..<14 {
            for x in 8..<21 where x < 12 || y >= 11 {
                for channel in 0..<3 { bytes[(y * width + x) * 4 + channel] = 20 }
            }
        }
        let current = Raster(width: width, height: height, rgba: bytes)
        let font = NSFont.systemFont(ofSize: 13)
        let foreground = M.Color(red: 0, green: 0, blue: 0, alpha: 1)
        let run = M.TextRun(location: 0, length: 1, font: .init(font),
            colors: [NSAttributedString.Key.foregroundColor.rawValue: foreground],
            rasterBounds: [CGRect(x: 8, y: 4, width: 13, height: 10)],
            inkMasks: [.init(origin: .zero, scale: 1, spans: (4..<14).map { y in
                .init(x: 8, y: y, length: y >= 11 ? 13 : 4)
            })])
        let metadata = M(elements: [.init(id: "label", role: "text", frame: CGRect(x: 0, y: 0, width: width, height: height),
            text: "L", lineBreaks: [.init(location: 0, length: 1)], textRuns: [run])])
        func shifted(_ amount: Double) -> Raster {
            var result = bytes
            for y in 0..<height {
                for x in 0..<width {
                    let source = max(0, Double(x) - amount), lower = Int(floor(source)), upper = min(width - 1, lower + 1)
                    for channel in 0..<4 {
                        let a = Double(bytes[(y * width + lower) * 4 + channel]), b = Double(bytes[(y * width + upper) * 4 + channel])
                        result[(y * width + x) * 4 + channel] = UInt8((a + (b - a) * (source - Double(lower))).rounded())
                    }
                }
            }
            return Raster(width: width, height: height, rgba: result)
        }
        func compare(_ candidate: Raster, _ candidateMetadata: M) -> ChatTimelineParity.BitmapResult {
            ChatTimelineParity.bitmap(current, candidate, currentLayout: metadata, candidateLayout: candidateMetadata,
                region: CGRect(x: 0, y: 0, width: width, height: height), scale: 1)
        }
        let translated = compare(shifted(0.5), metadata)
        XCTAssertTrue(translated.passes, "A single half-pixel bilinear translation is admissible")
        XCTAssertEqual(translated.textRuns.first?.translation, CGPoint(x: 0.5, y: 0))
        XCTAssertTrue(ChatTimelineParity.bitmap(shifted(0.5), current, currentLayout: metadata, candidateLayout: metadata,
            region: metadata.elements[0].frame, scale: 1).passes)
        var translatedBackground = shifted(0.5).rgba
        // Horizontal interpolation covers the new right edge, but no pixel
        // above the glyph. A square halo would incorrectly exempt this one.
        translatedBackground[(3 * width + 8) * 4] = 252
        let translatedMutation = Raster(width: width, height: height, rgba: translatedBackground)
        var translatedBackgroundRecords: [[String: Any]] = []
        for (direction, a, b) in [("forward", current, translatedMutation), ("reverse", translatedMutation, current)] {
            let result = ChatTimelineParity.bitmap(a, b, currentLayout: metadata, candidateLayout: metadata,
                region: metadata.elements[0].frame, scale: 1)
            XCTAssertTrue(result.textRuns.allSatisfy(\.passes))
            XCTAssertFalse(result.passes, "Accepted horizontal translation cannot exempt background above the run")
            translatedBackgroundRecords.append(["mutation": "translated-background-delta-three-" + direction,
                "expectedPass": false, "passed": result.passes])
        }
        XCTAssertFalse(compare(shifted(1), metadata).passes)
        XCTAssertFalse(compare(shifted(2), metadata).passes)
        var weight = metadata, size = metadata, colour = metadata, missing = metadata
        weight.elements[0].textRuns?[0].font = .init(.systemFont(ofSize: 13, weight: .semibold))
        size.elements[0].textRuns?[0].font = .init(.systemFont(ofSize: 14))
        colour.elements[0].textRuns?[0].colors[NSAttributedString.Key.foregroundColor.rawValue] = .init(red: 0.1, green: 0, blue: 0, alpha: 1)
        missing.elements[0].textRuns = nil
        var records: [[String: Any]] = [["mutation": "pure-half-pixel-translation", "expectedPass": true,
            "passed": translated.passes]] + translatedBackgroundRecords
        for (name, changed) in [("weight", weight), ("one-point size", size), ("colour", colour), ("missing metadata", missing)] {
            let result = compare(current, changed)
            XCTAssertFalse(result.passes, "Even identical pixels cannot excuse a changed \(name)")
            XCTAssertFalse(result.textRuns.allSatisfy(\.descriptorMatches))
            records.append(["mutation": name, "expectedPass": false, "passed": result.passes])
        }
        for amount in [1.0, 2.0] {
            records.append(["mutation": "\(amount)-pixel-translation", "expectedPass": false, "passed": compare(shifted(amount), metadata).passes])
        }
        var distorted = shifted(0.5).rgba
        let opposite = shifted(-0.5).rgba
        distorted.replaceSubrange((11 * width * 4)..<bytes.count, with: opposite[(11 * width * 4)..<bytes.count])
        let inconsistent = compare(.init(width: width, height: height, rgba: distorted), metadata)
        XCTAssertFalse(inconsistent.passes, "One translation must explain the whole run, not individual edges")
        records.append(["mutation": "inconsistent-shifts-within-run", "expectedPass": false, "passed": inconsistent.passes])
        var extra = bytes
        extra[0] = 200
        XCTAssertFalse(compare(.init(width: width, height: height, rgba: extra), metadata).passes,
            "The text allowance must not absorb a non-text difference")
        var interior = bytes
        interior[(5 * width + 15) * 4] = 252
        XCTAssertFalse(compare(.init(width: width, height: height, rgba: interior), metadata).passes,
            "Blank pixels inside a text run retain the non-text delta-2 rule")
        records.append(["mutation": "interior-background-delta-three", "expectedPass": false,
            "passed": compare(.init(width: width, height: height, rgba: interior), metadata).passes])
        if let directory = ProcessInfo.processInfo.environment["AGENTPAD_CHAT_PARITY_EVIDENCE"] {
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("text-run-mutation-results.json"))
        }
    }

    @MainActor func testObservedOpaqueToolbarUsesNonTextGateWithoutExemptingAnyPixels() {
        typealias M = ChatTimelineParityMetadata
        let width = 84, height = 46
        let viewport = CGRect(x: 0, y: 0, width: width, height: height)
        let white = M.Color(red: 1, green: 1, blue: 1, alpha: 1)
        let toolbar = M.Element(id: "pane0/w05/toolbar", role: "control",
            frame: CGRect(x: 24, y: 4, width: 48, height: 34), colorTokens: ["background": white])
        let run = M.TextRun(location: 0, length: 1, font: .init(.systemFont(ofSize: 13)), colors: [:],
            rasterBounds: [CGRect(x: 4, y: 20, width: 76, height: 22)],
            inkMasks: [.init(origin: .zero, scale: 1, spans: (22..<34).flatMap { y in
                // The text's independent ink observation includes glyphs hidden
                // behind the toolbar, as real NSTextView layout does.
                [M.InkMask.Span(x: 8, y: y, length: y >= 30 ? 10 : 4),
                 M.InkMask.Span(x: 40, y: y, length: 20)]
            })])
        let body = M.Element(id: "pane0/message:target/body", role: "text", frame: viewport,
            text: "L", textRuns: [run])
        let metadata = M(elements: [body, toolbar])
        func raster(bodyShift: Int = 0, symbolShift: Int = 0, symbol: Bool = true) -> Raster {
            var bytes = Array(repeating: UInt8(255), count: width * height * 4)
            func darken(_ x: Int, _ y: Int) {
                for channel in 0..<3 { bytes[(y * width + x) * 4 + channel] = 20 }
            }
            for y in 22..<34 { for x in 8..<(y >= 30 ? 18 : 12) { darken(x + bodyShift, y) } }
            if symbol { for y in 22..<28 { for x in 42..<46 { darken(x + symbolShift, y) } } }
            return Raster(width: width, height: height, rgba: bytes)
        }
        let current = raster(), shiftedIcon = raster(symbolShift: 1)
        func compare(_ a: Raster, _ b: Raster, left: M? = nil, right: M? = nil) -> ChatTimelineParity.BitmapResult {
            ChatTimelineParity.bitmap(a, b, currentLayout: left ?? metadata, candidateLayout: right ?? metadata, region: viewport, scale: 1)
        }
        for (a, b) in [(current, shiftedIcon), (shiftedIcon, current)] {
            let result = compare(a, b)
            XCTAssertTrue(result.passes, "Observed toolbar symbols retain the frozen non-text rule")
            XCTAssertEqual(result.textRuns.first?.translation, .zero)
            XCTAssertEqual(result.textRuns.first?.maximumDelta, 0)
            XCTAssertGreaterThan(result.differentPixels, 0)
            let bare = M(elements: [body])
            XCTAssertFalse(compare(a, b, left: bare, right: bare).passes,
                "No toolbar observation means no occlusion classification")
        }
        XCTAssertFalse(compare(current, raster(bodyShift: 1)).passes,
            "Visible body text still rejects whole-pixel movement")
        XCTAssertFalse(compare(current, raster(symbol: false)).passes, "A missing toolbar symbol still fails")
        XCTAssertFalse(compare(raster(symbol: false), current).passes, "An extra toolbar symbol still fails")
        var background = current.rgba
        background[(24 * width + 50) * 4] = 252
        let changed = Raster(width: width, height: height, rgba: background)
        for (a, b) in [(current, changed), (changed, current)] {
            let result = compare(a, b)
            XCTAssertTrue(result.textRuns.allSatisfy(\.passes))
            XCTAssertFalse(result.passes, "Hidden body ink must not exempt toolbar background delta three")
            XCTAssertGreaterThan(result.unmatchedCurrentPixels + result.unmatchedCandidatePixels, 0)
        }
        var moved = metadata, translucent = metadata
        moved.elements[1].frame.origin.x += 1
        translucent.elements[1].colorTokens["background"]?.alpha = 0.5
        XCTAssertFalse(compare(current, shiftedIcon, right: moved).passes)
        XCTAssertFalse(ChatTimelineParity.compare(currentLayout: metadata, candidateLayout: moved,
            current: current, candidate: current).passes, "Toolbar geometry remains exact")
        XCTAssertFalse(compare(current, shiftedIcon, left: translucent, right: translucent).passes,
            "A translucent toolbar cannot hide underlying text pixels")
    }

    @MainActor func testTextDeltaSixteenIsPerChannelAndAlphaRemainsExact() {
        typealias M = ChatTimelineParityMetadata
        let rect = CGRect(x: 0, y: 0, width: 4, height: 1)
        let metadata = M(elements: [.init(id: "glyph", role: "text", frame: rect, text: "—",
            textRuns: [.init(location: 0, length: 1, font: .init(.systemFont(ofSize: 13)), colors: [:],
                rasterBounds: [rect], inkMasks: [.init(origin: .zero, scale: 1, spans: [.init(x: 0, y: 0, length: 4)])])])])
        let current = image(Array(repeating: [50, 80, 110, 255], count: 4))
        func result(_ pixel: [UInt8]) -> Bool {
            ChatTimelineParity.bitmap(current, image(Array(repeating: pixel, count: 4)),
                currentLayout: metadata, candidateLayout: metadata, region: rect, scale: 1).passes
        }
        XCTAssertTrue(result([66, 96, 126, 255]))
        XCTAssertFalse(result([67, 80, 110, 255]))
        XCTAssertFalse(result([50, 97, 110, 255]))
        XCTAssertFalse(result([50, 80, 127, 255]))
        XCTAssertFalse(result([50, 80, 110, 254]))
    }

    @MainActor func testNonInkPixelBesideGlyphRetainsBackgroundTolerance() throws {
        typealias M = ChatTimelineParityMetadata
        // The reviewer's plain-760-light crop, physical pixels x=133..<139,
        // y=148..<153. Pixel (135,150) is background beside the glyph at
        // (136,151), outside both independently observed ink masks.
        let background: [UInt8] = [250, 250, 250, 255]
        let pixels: [[UInt8]] = [
            background, background, background, background, [236, 236, 236, 255], [60, 62, 69, 255],
            background, background, background, background, [169, 170, 173, 255], [56, 58, 65, 255],
            background, background, background, background, [97, 98, 104, 255], [56, 58, 65, 255],
            background, background, background, [228, 228, 229, 255], [56, 58, 65, 255], [56, 58, 65, 255],
            background, background, background, background, background, background
        ]
        let rect = CGRect(x: 0, y: 0, width: 6, height: 5)
        let metadata = M(elements: [.init(id: "body-crop", role: "text", frame: rect, text: "A",
            textRuns: [.init(location: 0, length: 1, font: .init(.systemFont(ofSize: 14)), colors: [:],
                rasterBounds: [rect], inkMasks: [.init(origin: .zero, scale: 1, spans: [
                    .init(x: 4, y: 0, length: 2), .init(x: 4, y: 1, length: 2),
                    .init(x: 4, y: 2, length: 2), .init(x: 3, y: 3, length: 3)
                ])])])])
        let current = Raster(width: 6, height: 5, rgba: pixels.flatMap { $0 })
        var changed = current.rgba
        changed[(2 * 6 + 2) * 4] = 247
        let candidate = Raster(width: 6, height: 5, rgba: changed)
        var records: [[String: Any]] = []
        for (name, left, right) in [("forward", current, candidate), ("reverse", candidate, current)] {
            let result = ChatTimelineParity.bitmap(left, right, currentLayout: metadata,
                candidateLayout: metadata, region: rect, scale: 1)
            XCTAssertEqual(result.textRuns.first?.translation, .zero)
            XCTAssertTrue(result.textRuns.allSatisfy(\.passes), "Delta 3 alone meets the text rule")
            XCTAssertFalse(result.passes, "Non-ink (250,250,250) → (247,250,250) must fail check 3")
            XCTAssertEqual(result.unmatchedCurrentPixels + result.unmatchedCandidatePixels, 1)
            records.append(["direction": name, "expectedPass": false, "passed": result.passes,
                "unmatchedCurrentPixels": result.unmatchedCurrentPixels,
                "unmatchedCandidatePixels": result.unmatchedCandidatePixels])
        }
        if let directory = ProcessInfo.processInfo.environment["AGENTPAD_CHAT_PARITY_EVIDENCE"] {
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("glyph-neighbour-mutation-results.json"))
        }
    }

    @MainActor func testInlineEditorCompositeObservesInnerClipAndRetainsFullDocumentSemantics() throws {
        typealias M = ChatTimelineParityMetadata
        _ = NSApplication.shared
        let host = ChatParityClipHost(frame: CGRect(x: 0, y: 0, width: 180, height: 80))
        let scroll = NSScrollView(frame: CGRect(x: 10, y: 10, width: 160, height: 50))
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 160, height: 400))
        editor.isEditable = true; editor.isHorizontallyResizable = false
        editor.textContainerInset = .zero
        editor.textContainer?.widthTracksTextView = true
        editor.backgroundColor = .white
        let content = NSMutableAttributedString(string: "Hidden styled line\n" + String(repeating: "Visible editable text.\n", count: 12),
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
        content.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 17), range: NSRange(location: 0, length: 6))
        editor.textStorage?.setAttributedString(content)
        scroll.documentView = editor; host.addSubview(scroll)
        host.layoutSubtreeIfNeeded()
        editor.layoutManager?.ensureLayout(for: try XCTUnwrap(editor.textContainer))
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 100)); scroll.reflectScrolledClipView(scroll.contentView)
        let clip = ChatTimelineParityLayout.frame(scroll.contentView.bounds, from: scroll.contentView, in: host)
        XCTAssertFalse(clip.isEmpty)
        let composite = try ChatTimelineParityLayout.text(editor, id: "editor", in: host)
        let standalone = try ChatTimelineParityLayout.text(editor, id: "editor", in: editor)
        XCTAssertEqual(composite.text, standalone.text)
        XCTAssertEqual(composite.lineBreaks, standalone.lineBreaks)
        XCTAssertEqual(composite.colorRuns, standalone.colorRuns)
        XCTAssertEqual(composite.textRuns, standalone.textRuns, "Full font/color/range semantics remain unchanged")
        let clippedRuns = try XCTUnwrap(composite.textRuns), fullRuns = try XCTUnwrap(standalone.textRuns)
        XCTAssertEqual(clippedRuns.count, 2)
        XCTAssertTrue(clippedRuns.flatMap(\.rasterBounds).allSatisfy { clip.contains($0) })
        XCTAssertTrue(try XCTUnwrap(clippedRuns.first?.inkMasks).allSatisfy { $0.spans.isEmpty },
            "The independently styled offscreen run exempts no pixels")
        XCTAssertFalse(try XCTUnwrap(fullRuns.first?.inkMasks).flatMap(\.spans).isEmpty,
            "Standalone editor capture retains the hidden document's glyphs")
        let visibleMasks = try XCTUnwrap(clippedRuns.last?.inkMasks)
        XCTAssertFalse(visibleMasks.flatMap(\.spans).isEmpty)
        for mask in visibleMasks {
            for span in mask.spans {
                let rect = CGRect(x: mask.origin.x + CGFloat(span.x) / mask.scale,
                    y: mask.origin.y + CGFloat(span.y) / mask.scale,
                    width: CGFloat(span.length) / mask.scale, height: 1 / mask.scale)
                XCTAssertTrue(clip.contains(rect), "Ink recording must clip its antialias margin too")
            }
        }
        let metadata = M(elements: [composite])
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let raster = try Raster(image)
        let scale = CGFloat(raster.width) / host.bounds.width
        func compare(_ candidate: Raster, _ observation: M) -> ChatTimelineParity.BitmapResult {
            ChatTimelineParity.bitmap(raster, candidate, currentLayout: metadata, candidateLayout: observation,
                region: host.bounds, scale: scale)
        }
        XCTAssertTrue(compare(raster, metadata).passes)
        var inkPixel: Int?
        for mask in visibleMasks {
            for span in mask.spans {
                for offset in 0..<span.length {
                    let x = Int(((mask.origin.x + CGFloat(span.x + offset) / mask.scale) * scale).rounded(.down))
                    let y = Int(((mask.origin.y + CGFloat(span.y) / mask.scale) * scale).rounded(.down))
                    guard x >= 0, y >= 0, x < raster.width, y < raster.height else { continue }
                    let index = (y * raster.width + x) * 4
                    if raster.rgba[index] < 128 { inkPixel = index; break }
                }
                if inkPixel != nil { break }
            }
            if inkPixel != nil { break }
        }
        let index = try XCTUnwrap(inkPixel, "The composite must actually draw visible editor ink")
        var changed = raster.rgba
        changed[index] = 255; changed[index + 1] = 0; changed[index + 2] = 255
        XCTAssertFalse(compare(Raster(width: raster.width, height: raster.height, rgba: changed), metadata).passes,
            "Visible editor corruption still fails the frozen comparator")
        var changedMetadata = metadata
        changedMetadata.elements[0].textRuns?[0].font = .init(.systemFont(ofSize: 19))
        XCTAssertFalse(compare(raster, changedMetadata).passes, "Offscreen font semantics remain exact")
        editor.isEditable = false
        let body = try ChatTimelineParityLayout.text(editor, id: "editor", in: host)
        XCTAssertFalse(try XCTUnwrap(body.textRuns?.first?.inkMasks).flatMap(\.spans).isEmpty,
            "Readonly body text keeps its existing full raster observations")
    }
}

@MainActor private final class ChatParityClipHost: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.white.setFill(); dirtyRect.fill() }
}
