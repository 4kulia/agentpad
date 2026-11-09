import AppKit
import AgentPadQuietTestSupport
import CryptoKit
import SwiftUI
import XCTest
import zlib

@MainActor final class ChatTimelineCaptureColorTests: XCTestCase {
    func testQuietHostsAndPNGsUseFrozenW00ColorSpace() async throws {
        XCTAssertTrue(APQuietIsEnabled())
        _ = NSApplication.shared
        // All 1,040 frozen W00 PNGs embed this exact profile. Keep its identity
        // independent of the implementation so a host/display fallback is red.
        let expected = "96ea8786829fd2cbf8b7e143e31bedb50d53c099e33150b2c3786b2c9e723c84"
        func digest(_ profile: Data?) throws -> String {
            SHA256.hash(data: try XCTUnwrap(profile)).map { String(format: "%02x", $0) }.joined()
        }
        for dark in [false, true] {
            for width: CGFloat in [760, 420] {
                for legacy in [true, false] {
                    let host = legacy
                        ? ChatQuietHost(content: AnyView(Color(nsColor: CaptureSwatch.color)), dark: dark, width: width, height: 40)
                        : ChatQuietHost(view: CaptureSwatch(), dark: dark, width: width, height: 40)
                    defer { host.close() }
                    try await host.settle()
                    XCTAssertEqual(try digest(host.window.colorSpace?.iccProfileData), expected)
                    var first: ChatTimelineParity.Raster?
                    for _ in 0..<3 {
                        let bitmap = try ChatNativeMetadataParity.bitmap(host.view)
                        XCTAssertEqual(try digest(bitmap.colorSpace.iccProfileData), expected)
                        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
                        XCTAssertEqual(try digest(Self.storedProfile(png)), expected)
                        let pixels = try ChatTimelineParity.Raster(decoded)
                        if let first { XCTAssertEqual(ChatTimelineParity.exactDifference(first, pixels), 0) }
                        else { first = pixels }
                    }
                }
            }
        }
        XCTAssertNil(APQuietFailure())
    }

    /// Read the actual PNG bytes: AppKit normalizes ICC headers on decode,
    /// including the colorSyncProfileData property, so that is not file proof.
    private static func storedProfile(_ png: Data) throws -> Data {
        let bytes = [UInt8](png)
        var offset = 8
        while offset + 12 <= bytes.count {
            let count = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            let end = offset + 8 + count
            guard end + 4 <= bytes.count else { break }
            if Array(bytes[offset + 4..<offset + 8]) == Array("iCCP".utf8) {
                let separator = try XCTUnwrap(bytes[(offset + 8)..<end].firstIndex(of: 0))
                XCTAssertEqual(bytes[separator + 1], 0, "PNG ICC compression must be zlib")
                let compressed = Array(bytes[(separator + 2)..<end])
                var decoded = [UInt8](repeating: 0, count: 3376) // Frozen W00 profile size.
                var length = uLongf(decoded.count)
                XCTAssertEqual(uncompress(&decoded, &length, compressed, uLong(compressed.count)), Z_OK)
                XCTAssertEqual(Int(length), decoded.count)
                return Data(decoded)
            }
            offset = end + 4
        }
        throw NSError(domain: "Capture PNG has no embedded ICC profile", code: 1)
    }
}

@MainActor private final class CaptureSwatch: NSView {
    static var color: NSColor { NSColor(srgbRed: 0.23, green: 0.47, blue: 0.71, alpha: 1) }
    override func draw(_ dirtyRect: NSRect) {
        Self.color.setFill()
        bounds.fill()
    }
}
