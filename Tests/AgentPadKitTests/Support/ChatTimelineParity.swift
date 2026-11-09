import AppKit
import XCTest

/// Shared W03–W09 gate. Layout is compared independently and exactly; the only
/// bitmap allowances are the owner's per-run sub-pixel text rule and symmetric
/// one-pixel / delta-2 rule for the remaining pixels.
enum ChatTimelineParity {
    struct Result: Codable, Equatable {
        let layoutMatches: Bool
        let bitmap: BitmapResult
        var passes: Bool { layoutMatches && bitmap.passes }
    }

    struct BitmapResult: Codable, Equatable {
        let dimensionsMatch: Bool
        let differentPixels: Int
        let unmatchedCurrentPixels: Int
        let unmatchedCandidatePixels: Int
        let unmatchedBounds: CGRect?
        var textRuns: [TextRunResult] = []
        var passes: Bool {
            dimensionsMatch && unmatchedCurrentPixels == 0 && unmatchedCandidatePixels == 0
                && textRuns.allSatisfy(\.passes)
        }
    }

    struct TextRunResult: Codable, Equatable {
        let id: String
        let descriptorMatches: Bool
        let translation: CGPoint
        let resampledCurrent: Bool
        let maximumDelta: Double
        let unmatchedPixels: Int
        var passes: Bool { descriptorMatches && unmatchedPixels == 0 }
    }

    struct Raster {
        let width: Int
        let height: Int
        let rgba: [UInt8]

        init(width: Int, height: Int, rgba: [UInt8]) {
            precondition(width > 0 && height > 0 && rgba.count == width * height * 4)
            self.width = width; self.height = height; self.rgba = rgba
        }

        init(_ image: NSBitmapImageRep) throws {
            width = image.pixelsWide; height = image.pixelsHigh
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: width, height: height))
            let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            var bytes = Array(UnsafeBufferPointer(start: data, count: width * height * 4))
            // Compare sRGB components, not alpha-weighted components. Alpha is
            // independently exact, including when searching a neighbouring pixel.
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let alpha = Int(bytes[offset + 3])
                if alpha > 0 && alpha < 255 {
                    for channel in 0..<3 {
                        bytes[offset + channel] = UInt8(min(255, (Int(bytes[offset + channel]) * 255 + alpha / 2) / alpha))
                    }
                }
            }
            rgba = bytes
        }
    }

    static func compare<Layout: Equatable>(currentLayout: Layout, candidateLayout: Layout,
                                           current: Raster, candidate: Raster) -> Result {
        Result(layoutMatches: currentLayout == candidateLayout, bitmap: bitmap(current, candidate))
    }

    static func compare(currentLayout: ChatTimelineParityMetadata, candidateLayout: ChatTimelineParityMetadata,
                        current: Raster, candidate: Raster) -> Result {
        let viewport = currentLayout.elements.first { $0.role == "viewport" }?.frame
            ?? CGRect(x: 0, y: 0, width: current.width, height: current.height)
        return Result(layoutMatches: currentLayout.captureGaps.isEmpty && candidateLayout.captureGaps.isEmpty
            && !currentLayout.elements.isEmpty && currentLayout == candidateLayout,
            bitmap: bitmap(current, candidate, currentLayout: currentLayout, candidateLayout: candidateLayout,
                region: viewport, scale: CGFloat(current.width) / viewport.width))
    }

    /// The frozen W00/current-legacy drift check retains strict equality.
    static func exactDifference(_ lhs: Raster, _ rhs: Raster) -> Int {
        guard lhs.width == rhs.width, lhs.height == rhs.height else {
            return max(lhs.width * lhs.height, rhs.width * rhs.height)
        }
        if lhs.rgba == rhs.rgba { return 0 }
        return lhs.rgba.withUnsafeBytes { left in
            rhs.rgba.withUnsafeBytes { right in
                let a = left.bindMemory(to: UInt32.self), b = right.bindMemory(to: UInt32.self)
                return a.indices.reduce(0) { $0 + (a[$1] == b[$1] ? 0 : 1) }
            }
        }
    }

    static func bitmap(_ current: Raster, _ candidate: Raster) -> BitmapResult {
        nonTextBitmap(current, candidate, textPixels: [])
    }

    private static func nonTextBitmap(_ current: Raster, _ candidate: Raster, textPixels: Set<Int>) -> BitmapResult {
        guard current.width == candidate.width, current.height == candidate.height else {
            return BitmapResult(dimensionsMatch: false,
                differentPixels: max(current.width * current.height, candidate.width * candidate.height),
                unmatchedCurrentPixels: current.width * current.height,
                unmatchedCandidatePixels: candidate.width * candidate.height, unmatchedBounds: nil)
        }
        let width = current.width, height = current.height
        var different = 0, unmatchedCurrent = 0, unmatchedCandidate = 0
        var bounds: CGRect?
        current.rgba.withUnsafeBytes { leftBytes in
            candidate.rgba.withUnsafeBytes { rightBytes in
                let left = leftBytes.bindMemory(to: UInt8.self), right = rightBytes.bindMemory(to: UInt8.self)
                let leftPixels = leftBytes.bindMemory(to: UInt32.self), rightPixels = rightBytes.bindMemory(to: UInt32.self)
                func counterpart(_ source: UnsafeBufferPointer<UInt8>, _ target: UnsafeBufferPointer<UInt8>,
                                 offset: Int, x: Int, y: Int) -> Bool {
                    for yy in max(0, y - 1)...min(height - 1, y + 1) {
                        for xx in max(0, x - 1)...min(width - 1, x + 1) {
                            let other = (yy * width + xx) * 4
                            if source[offset + 3] == target[other + 3]
                                && abs(Int(source[offset]) - Int(target[other])) <= 2
                                && abs(Int(source[offset + 1]) - Int(target[other + 1])) <= 2
                                && abs(Int(source[offset + 2]) - Int(target[other + 2])) <= 2 { return true }
                        }
                    }
                    return false
                }
                for y in 0..<height {
                    for x in 0..<width {
                        let pixelIndex = y * width + x
                        if leftPixels[pixelIndex] == rightPixels[pixelIndex] { continue }
                        let offset = pixelIndex * 4
                        different += 1
                        if textPixels.contains(pixelIndex) { continue }
                        let forward = counterpart(left, right, offset: offset, x: x, y: y)
                        let reverse = counterpart(right, left, offset: offset, x: x, y: y)
                        if !forward { unmatchedCurrent += 1 }
                        if !reverse { unmatchedCandidate += 1 }
                        if !forward || !reverse {
                            let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                            bounds = bounds.map { $0.union(pixel) } ?? pixel
                        }
                    }
                }
            }
        }
        return BitmapResult(dimensionsMatch: true, differentPixels: different,
            unmatchedCurrentPixels: unmatchedCurrent, unmatchedCandidatePixels: unmatchedCandidate,
            unmatchedBounds: bounds)
    }

    /// One translation for the entire attribute run, including every line it
    /// spans. Bounds come from each renderer's observed text layout, never from
    /// the locations of differing pixels. Missing metadata fails closed.
    static func bitmap(_ current: Raster, _ candidate: Raster,
                       currentLayout: ChatTimelineParityMetadata, candidateLayout: ChatTimelineParityMetadata,
                       region: CGRect, scale: CGFloat) -> BitmapResult {
        guard current.width == candidate.width, current.height == candidate.height else { return bitmap(current, candidate) }
        let left = Dictionary(uniqueKeysWithValues: currentLayout.elements.filter { $0.text != nil }.map { ($0.id, $0) })
        let right = Dictionary(uniqueKeysWithValues: candidateLayout.elements.filter { $0.text != nil }.map { ($0.id, $0) })
        var pixels: Set<Int> = []
        var results: [TextRunResult] = []
        let toolbarOcclusions = opaqueToolbarCores(currentLayout, candidateLayout,
            region: region, scale: scale, width: current.width, height: current.height)
        for id in Set(left.keys).union(right.keys).sorted() {
            let a = left[id], b = right[id]
            let aa = a?.textRuns ?? [], bb = b?.textRuns ?? []
            guard !aa.isEmpty, aa.count == bb.count, a?.text == b?.text else {
                results.append(.init(id: id, descriptorMatches: false, translation: .zero,
                    resampledCurrent: true, maximumDelta: 255, unmatchedPixels: 1)); continue
            }
            for index in aa.indices {
                let currentRun = aa[index], candidateRun = bb[index]
                let descriptorsMatch = currentRun == candidateRun && a?.opacity == b?.opacity
                let visible = a?.opacity != 0 || b?.opacity != 0
                let bounds = visible ? currentRun.rasterBounds + candidateRun.rasterBounds : []
                var runPixels: Set<Int> = []
                for rect in bounds {
                    let clipped = CGRect(x: (rect.minX - region.minX) * scale,
                        y: (rect.minY - region.minY) * scale, width: rect.width * scale, height: rect.height * scale)
                        .insetBy(dx: -1, dy: -1).integral
                        .intersection(CGRect(x: 0, y: 0, width: current.width, height: current.height))
                    if !clipped.isNull && !clipped.isEmpty {
                        for y in Int(clipped.minY)..<Int(clipped.maxY) {
                            for x in Int(clipped.minX)..<Int(clipped.maxX) { runPixels.insert(y * current.width + x) }
                        }
                    }
                }
                // A floating toolbar is above message text. Its fully opaque
                // interior contains toolbar symbols/background, not pixels of
                // the underlying text run. Keep those pixels in the unchanged
                // non-text gate, including where the hidden run's ink mask
                // crosses them. Rounded corners remain fail-closed text scope.
                for occlusion in toolbarOcclusions where id.hasPrefix(occlusion.messagePrefix) {
                    runPixels.subtract(occlusion.pixels)
                }
                // Invisible and outside-region runs still require equal fonts
                // and colour tokens. Visible in-region text needs real bounds.
                let hasBounds = !visible || (!currentRun.rasterBounds.isEmpty && !candidateRun.rasterBounds.isEmpty
                    && currentRun.inkMasks != nil && candidateRun.inkMasks != nil)
                let comparison = textRun(current, candidate, pixels: runPixels.sorted(), id: "\(id):\(currentRun.location):\(currentRun.length)",
                    descriptorMatches: descriptorsMatch && hasBounds)
                results.append(comparison)
                // A text rectangle also contains background. Exempt only ink
                // with positive coverage in the accepted comparison: the
                // translated source and the unshifted target. At zero shift
                // there is no interpolation support outside the observed ink.
                if visible && comparison.passes {
                    let source = comparison.resampledCurrent ? currentRun : candidateRun
                    let target = comparison.resampledCurrent ? candidateRun : currentRun
                    let translatedInk = inkPixels(source.inkMasks ?? [], translation: comparison.translation,
                        region: region, scale: scale, width: current.width, height: current.height)
                    let targetInk = inkPixels(target.inkMasks ?? [], translation: .zero,
                        region: region, scale: scale, width: current.width, height: current.height)
                    pixels.formUnion(runPixels.intersection(translatedInk.union(targetInk)))
                }
            }
        }
        var result = nonTextBitmap(current, candidate, textPixels: pixels)
        result.textRuns = results
        return result
    }

    /// R22 already specifies the toolbar's opaque surface and eight-point
    /// rounded corners. Use only the rectangular opaque core, from matching
    /// independently observed controls; never derive regions from differences.
    /// Every omitted text-sampling pixel still receives the stricter non-text
    /// comparison. A missing/moved/translucent toolbar grants no classification.
    private static func opaqueToolbarCores(_ current: ChatTimelineParityMetadata,
                                           _ candidate: ChatTimelineParityMetadata,
                                           region: CGRect, scale: CGFloat, width: Int, height: Int)
        -> [(messagePrefix: String, pixels: Set<Int>)] {
        let suffix = "w05/toolbar"
        let right = Dictionary(uniqueKeysWithValues: candidate.elements.filter {
            $0.id == suffix || $0.id.hasSuffix("/" + suffix)
        }.map { ($0.id, $0) })
        return current.elements.compactMap { element in
            guard (element.id == suffix || element.id.hasSuffix("/" + suffix)),
                  element.role == "control", element == right[element.id],
                  element.opacity == 1, element.colorTokens["background"]?.alpha == 1,
                  element.frame.width > 16, element.frame.height > 16 else { return nil }
            // Continuous corners extend beyond the nominal radius; use
            // the actual drawing path's maximal corner reach, not a circle.
            let reach: CGFloat = 8 * 1.5286649465560913
            let cores = [element.frame.insetBy(dx: reach, dy: 0), element.frame.insetBy(dx: 0, dy: reach)]
            var pixels: Set<Int> = []
            for core in cores {
                // Inward rounding retains only pixels wholly inside the core.
                let minX = max(0, Int(ceil((core.minX - region.minX) * scale)))
                let minY = max(0, Int(ceil((core.minY - region.minY) * scale)))
                let maxX = min(width, Int(floor((core.maxX - region.minX) * scale)))
                let maxY = min(height, Int(floor((core.maxY - region.minY) * scale)))
                guard minX < maxX, minY < maxY else { continue }
                for y in minY..<maxY { for x in minX..<maxX { pixels.insert(y * width + x) } }
            }
            return (String(element.id.dropLast(suffix.count)) + "message:", pixels)
        }
    }

    /// Ink spans encode strictly positive glyph alpha. Translating their pixel
    /// intervals before integralization includes precisely the nonzero bilinear
    /// support, including fractional diagonal shifts, without adding a halo.
    private static func inkPixels(_ masks: [ChatTimelineParityMetadata.InkMask], translation: CGPoint,
                                  region: CGRect, scale: CGFloat, width: Int, height: Int) -> Set<Int> {
        var pixels: Set<Int> = []
        for mask in masks {
            for span in mask.spans {
                let covered = CGRect(x: (mask.origin.x + CGFloat(span.x) / mask.scale - region.minX) * scale + translation.x,
                    y: (mask.origin.y + CGFloat(span.y) / mask.scale - region.minY) * scale + translation.y,
                    width: CGFloat(span.length) * scale / mask.scale, height: scale / mask.scale)
                    .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
                if !covered.isNull && !covered.isEmpty {
                    for y in Int(covered.minY)..<Int(covered.maxY) {
                        for x in Int(covered.minX)..<Int(covered.maxX) { pixels.insert(y * width + x) }
                    }
                }
            }
        }
        return pixels
    }

    private static func textRun(_ current: Raster, _ candidate: Raster, pixels: [Int],
                                id: String, descriptorMatches: Bool) -> TextRunResult {
        func sample(_ image: Raster, x: Double, y: Double, channel: Int) -> Double {
            let x = min(Double(image.width - 1), max(0, x)), y = min(Double(image.height - 1), max(0, y))
            let x0 = Int(floor(x)), y0 = Int(floor(y)), x1 = min(x0 + 1, image.width - 1), y1 = min(y0 + 1, image.height - 1)
            let fx = x - Double(x0), fy = y - Double(y0)
            func value(_ xx: Int, _ yy: Int) -> Double { Double(image.rgba[(yy * image.width + xx) * 4 + channel]) }
            return (value(x0, y0) * (1 - fx) + value(x1, y0) * fx) * (1 - fy)
                + (value(x0, y1) * (1 - fx) + value(x1, y1) * fx) * fy
        }
        func evaluate(dx: Double, dy: Double, forward: Bool) -> TextRunResult {
            let source = forward ? current : candidate, target = forward ? candidate : current
            var maximum = 0.0, unmatched = 0
            for pixel in pixels {
                let x = Double(pixel % source.width), y = Double(pixel / source.width)
                var delta = 0.0
                for channel in 0..<3 {
                    let value = dx == 0 && dy == 0 ? Double(source.rgba[pixel * 4 + channel])
                        : sample(source, x: x - dx, y: y - dy, channel: channel)
                    delta = max(delta, abs(value - Double(target.rgba[pixel * 4 + channel])))
                }
                let sourceAlpha = dx == 0 && dy == 0 ? Double(source.rgba[pixel * 4 + 3])
                    : sample(source, x: x - dx, y: y - dy, channel: 3)
                let alpha = abs(sourceAlpha - Double(target.rgba[pixel * 4 + 3]))
                maximum = max(maximum, delta)
                if delta > 16 || alpha > 0 { unmatched += 1 }
            }
            return .init(id: id, descriptorMatches: descriptorMatches, translation: CGPoint(x: dx, y: dy),
                resampledCurrent: forward, maximumDelta: maximum, unmatchedPixels: unmatched)
        }
        var best = evaluate(dx: 0, dy: 0, forward: true)
        if best.unmatchedPixels == 0 { return best }
        for y in -3...3 {
            for x in -3...3 where x != 0 || y != 0 {
                let dx = Double(x) / 4, dy = Double(y) / 4
                guard dx * dx + dy * dy < 1 else { continue }
                for forward in [true, false] {
                    let result = evaluate(dx: dx, dy: dy, forward: forward)
                    if result.maximumDelta < best.maximumDelta
                        || result.maximumDelta == best.maximumDelta && result.unmatchedPixels < best.unmatchedPixels { best = result }
                }
            }
        }
        return best
    }
}
