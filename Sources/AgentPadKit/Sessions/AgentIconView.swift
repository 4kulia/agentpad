import AppKit
import ImageIO
import SwiftUI

/// Loader for the bundled lobe-icons PNGs. Chosen over SVG because Apple's
/// CoreSVG renderer mis-parses lobe's compact arc-flag form (gemini-color is
/// the canonical victim) and the 640×640 PNGs are plenty for tab/menu usage.
///
/// Cached because `AgentIconView.body` calls this on every SwiftUI re-render
/// (hover, scroll, OSC 7 push) — without the cache each call paid a stat +
/// PNG decode.
@MainActor
enum AgentIcon {
    private static var cache: [String: NSImage?] = [:]

    /// Asset names whose bundled lobe-icon is a single-color (white) mark with
    /// the glyph carried in the alpha channel. Drawn as-is they disappear on
    /// light themes — the chrome inverts but the PNG stays white — so
    /// `AgentIconView` template-renders these tinted with `Theme.chromeForeground`
    /// instead. Color-brand marks (claudecode / codex / gemini / amp /
    /// antigravity) are intentionally absent: they keep their own colors on
    /// every theme. Keyed on `iconAsset`, so a custom agent based on a mono
    /// brand inherits the treatment for free. `nonisolated` so the predicate
    /// is reachable from tests without hopping to the main actor.
    nonisolated static let monochromeAssets: Set<String> = ["opencode", "cursor", "githubcopilot", "grok", "kimi", "pi", "droid"]

    nonisolated static func isMonochrome(_ asset: String) -> Bool {
        monochromeAssets.contains(asset)
    }

    /// Logical size is scaled to a 16pt longest edge, not forced to a 16×16
    /// square: SwiftUI's `.scaledToFit()` takes its aspect ratio from
    /// `image.size`, so squaring it stretches a non-square mark to fill the
    /// frame. Square was safe while every asset was a 640×640 bundled icon;
    /// an imported wordmark is the first source that isn't. Pixel data is
    /// untouched, so `.resizable()` callers still render sharp at any size.
    ///
    /// Bundled builtin marks win; a miss falls through to the user's imported
    /// custom icons in App Support. The two namespaces can't collide —
    /// `AgentIconStore` names its files `<agentId>-<uuid8>.png`, and no
    /// builtin asset name carries an extension (pinned by
    /// `testBuiltinIconAssetsCarryNoExtension`) — so the fallthrough needs no
    /// discriminator on the stored string, which is what lets
    /// `CustomAgentData.iconAsset` and every downstream consumer
    /// (`fromCustom` inheritance, the inbox's icon snapshot, the command
    /// palette) carry a custom icon with zero call-site changes.
    ///
    /// Misses are cached too. A stored name whose file is gone is an ordinary
    /// state now (settings.json syncs between Macs; App Support doesn't), and
    /// an uncached miss re-pays a bundle probe plus a `stat` on every
    /// re-render — the exact per-render cost this cache exists to remove.
    static func nsImage(asset: String) -> NSImage? {
        if let hit = cache[asset] { return hit }
        let url = bundleResourceURL(name: asset, ext: "png", subdirectory: "Icons")
            ?? AgentIconStore.existingURL(for: asset)
        guard let url, let image = NSImage(contentsOf: url) else {
            cache.updateValue(nil, forKey: asset)
            return nil
        }
        if let fitted = AgentIconStore.fittedSize(for: image, longEdge: 16) {
            image.size = fitted
        }
        cache.updateValue(image, forKey: asset)
        return image
    }

    /// Drops every cached image. Called after the store deletes files, so a
    /// removed icon stops rendering immediately — `NSImage` keeps drawing
    /// happily from memory once its backing file is gone, which would
    /// otherwise defer the change to the next launch.
    static func invalidateCache() {
        cache.removeAll()
    }
}

/// On-disk store for user-imported custom agent icons (issue #40).
///
/// Imported images are copied into App Support rather than referenced in
/// place: the user typically picks out of `~/Downloads`, and a moved or
/// deleted source would silently blank the icon later. Every import is
/// normalised to PNG so the loader has exactly one format to decode, and
/// so a vector source that AppKit renders wrong shows the damage in the
/// Settings preview immediately instead of on every tab.
@MainActor
enum AgentIconStore {
    /// Longest edge of a stored icon. Display sizes top out at 20pt (the
    /// sidebar mark) and macOS backing scale tops out at 2× — there is no @3x
    /// on the Mac — so 40px is what actually gets drawn. 256 leaves 6× of
    /// headroom for a future larger surface while capping what the loader's
    /// cache holds resident: an unbounded import (a 4000×4000 logo off the
    /// web) would otherwise pin ~64MB per agent.
    static let maxDimension: CGFloat = 256

    /// Import floor surfaced as the Settings hint. ~40px is what actually gets
    /// drawn (20pt at 2×), but the hint names the familiar icon size instead:
    /// what it needs to keep out is a source *smaller* than the display size,
    /// which gets upscaled and visibly blurs. A 64px source downscales with
    /// only mild softening, and quoting the true 40px would just push users to
    /// shrink the perfectly good 512px logo they already have.
    static let recommendedDimension = 64

    /// Cheap guard against pointing the importer at something that isn't a
    /// logo. Decoding is the expensive step, so this runs before it.
    static let maxSourceBytes = 20 * 1024 * 1024

    /// Pixel-count ceiling, read from the file header *before* any decode.
    /// The byte limit above can't catch a decompression bomb — image formats
    /// compress uniform data thousands-to-one, so a 1MB PNG can expand to
    /// 30000×30000 (~3.6GB) and take the app down with it. 4000×4000 is
    /// already absurd for a 20pt mark and caps a worst-case decode at ~64MB.
    /// Vector sources carry no pixel dimensions and skip this check by
    /// construction: they rasterise at `maxDimension`, so their memory cost
    /// is fixed no matter how large the artboard claims to be.
    static let maxSourcePixels = 4000 * 4000

    enum ImportError: LocalizedError {
        case tooLarge
        case tooManyPixels
        case unreadable

        var errorDescription: String? {
            switch self {
            case .tooLarge: "That image is larger than 20 MB. Pick a smaller file."
            case .tooManyPixels: "That image's resolution is too high. Pick one under 4000×4000."
            case .unreadable: "Couldn't read that image. Try a PNG."
            }
        }
    }

    /// Test seam (same shape as `AgentPadShellIntegration.remotePasteProcessRunnerOverride`).
    /// Setting it also opts the process into `prune` — see `canPrune`.
    static var directoryOverride: URL?

    static var directory: URL {
        directoryOverride ?? AgentPadShellIntegration.agentPadAppSupport("agent-icons", isDirectory: true)
    }

    /// `prune` deletes files, so it stays inert until something opts in —
    /// CLAUDE.md's rule after the RecentFolders incident: write seams must be
    /// opt-in. `AppDelegate` calls `wireForApp()` at launch; an xctest process
    /// never does, so a future test that reaches `AgentPadSettingsModel.save()`
    /// can't sweep the developer's own imported logos. Tests that *do* exercise
    /// pruning set `directoryOverride`, which enables it against their temp dir.
    private static var isWiredForApp = false

    static func wireForApp() {
        isWiredForApp = true
    }

    private static var canPrune: Bool {
        isWiredForApp || directoryOverride != nil
    }

    /// Resolves a stored icon name to its file, or nil when the name isn't
    /// one of ours / the file is gone. Returning nil on a missing file is
    /// what makes a hand-deleted icon fall back to the SF Symbol instead of
    /// rendering an empty frame.
    static func existingURL(for fileName: String) -> URL? {
        guard !fileName.isEmpty, !fileName.contains("/") else { return nil }
        let url = directory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Imports `source` as `agentId`'s icon and returns the stored file name
    /// (to be written into `CustomAgentData.iconAsset`).
    ///
    /// Writes the new file and leaves the old one for `prune` — deleting
    /// first meant a failed write destroyed the icon the user already had,
    /// since the caller only assigns `iconAsset` on success and settings.json
    /// would keep naming the file just deleted. The fresh UUID keeps the write
    /// off any live `AgentIcon.cache` key.
    static func importIcon(from source: URL, agentId: String) throws -> String {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxSourceBytes else { throw ImportError.tooLarge }
        guard headerPixelCount(of: source) ?? 0 <= maxSourcePixels else { throw ImportError.tooManyPixels }
        // `NSImage(contentsOf:)` is the real format gate: anything AppKit
        // can't decode as an image — a renamed archive, a truncated file —
        // fails here regardless of what its extension claimed. What lands on
        // disk is then re-rendered pixels, never the source bytes, so no
        // metadata or trailing payload survives the import.
        guard let image = NSImage(contentsOf: source), let png = normalizedPNG(from: image) else {
            throw ImportError.unreadable
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(sanitize(agentId))-\(UUID().uuidString.prefix(8)).png"
        // `.atomic` so an interrupted write can't leave a truncated PNG under
        // a name `existingURL` accepts and `NSImage` then rejects on every
        // render.
        try png.write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }

    /// Deletes every stored icon no longer named by a live custom agent.
    ///
    /// Keyed on the exact stored file name, NOT a per-agent prefix. Prefix
    /// matching was wrong in both directions: it missed every bulk path
    /// (`resetAgentCustomisation`, a hand-edited settings.json, an agent
    /// `parseCustomAgents` drops, an id the user renames) and it over-matched
    /// across ids — `claude` swept `claude-fast-<uuid>.png`, and `sanitize`
    /// collapses `my.agent` and `my agent` onto one token. The live set is a
    /// stronger key and was already stored.
    ///
    /// Mirrors `AgentPadShellIntegration.refreshClaudeCustomSettings`, which
    /// live-set-sweeps the per-agent Claude settings files from the same
    /// `save()`.
    static func prune(keeping agents: [CustomAgentData]) {
        guard canPrune else { return }
        let live = Set(agents.map(\.iconAsset))
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        var removedAny = false
        for name in names where name.hasSuffix(".png") && !live.contains(name) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
            removedAny = true
        }
        if removedAny { AgentIcon.invalidateCache() }
    }

    /// Pixel count straight from the image header — `CGImageSource` reads
    /// metadata without decoding the bitmap, which is the whole point: the
    /// decode is what a bomb weaponises. Nil when the source declares no
    /// pixel dimensions (vectors, or an unreadable header), which the caller
    /// treats as "nothing to cap" — `NSImage` rejects the unreadable case a
    /// line later anyway.
    private static func headerPixelCount(of url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // Total, not trapping. A bare `width * height` traps on overflow, and
        // a negative dimension would sail through the caller's `<=` guard —
        // both currently unreachable (ImageIO caps every format's reported
        // dimensions far below Int64 and rejects implausible ones outright),
        // but this guard exists to survive malicious files, so it must not be
        // the thing that dies on one. `Int.max` reads as "reject".
        guard width >= 0, height >= 0 else { return .max }
        let (product, overflowed) = width.multipliedReportingOverflow(by: height)
        return overflowed ? .max : product
    }

    /// Agent ids come from settings.json, which the user can hand-edit — keep
    /// path separators and dots out of the file name so an id can never escape
    /// the icons directory or fake an extension. Lossy (every rejected scalar
    /// becomes `_`), which is safe only because the UUID suffix — not this
    /// token — carries uniqueness, and `prune` no longer matches on the token.
    private static func sanitize(_ id: String) -> String {
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(id.unicodeScalars.map { ok.contains($0) ? Character($0) : "_" })
        // Capped well under NAME_MAX so a long hand-edited id can't make every
        // write fail with ENAMETOOLONG.
        return cleaned.isEmpty ? "agent" : String(cleaned.prefix(64))
    }

    /// True pixel dimensions of the image's largest bitmap representation, or
    /// nil for a vector source (no pixels — its `size` is an artboard in
    /// points) or a repless one.
    private static func pixelSize(of image: NSImage) -> NSSize? {
        let longest = { (rep: NSImageRep) in max(rep.pixelsWide, rep.pixelsHigh) }
        guard let widest = image.representations
            .filter({ $0 is NSBitmapImageRep })
            .max(by: { longest($0) < longest($1) }),
              widest.pixelsWide > 0, widest.pixelsHigh > 0
        else { return nil }
        return NSSize(width: widest.pixelsWide, height: widest.pixelsHigh)
    }

    /// `image`'s true aspect ratio scaled into a box of `longEdge` on its
    /// longest side.
    ///
    /// Aspect comes from the bitmap rep's PIXELS, not `image.size`. The two
    /// disagree whenever a file carries non-square DPI metadata (a 2000×500
    /// PNG can report a 500×500 point size), and `image.size` is separately
    /// unreliable because `AgentIcon.nsImage` overwrites it on every image it
    /// caches. Vectors have no pixels, so they fall back to `size` — for them
    /// it is the artboard and its ratio is right.
    static func fittedSize(for image: NSImage, longEdge: CGFloat) -> NSSize? {
        let source = pixelSize(of: image) ?? image.size
        guard source.width > 0, source.height > 0, longEdge > 0 else { return nil }
        let scale = longEdge / max(source.width, source.height)
        return NSSize(
            width: max(1, (source.width * scale).rounded()),
            height: max(1, (source.height * scale).rounded())
        )
    }

    /// Rasterises to PNG, downscaling so the longest edge is at most
    /// `maxDimension`. Small sources are never upscaled.
    ///
    /// A vector rep has no pixels, so it rasterises at the full
    /// `maxDimension` rather than its point-sized artboard — honouring that
    /// would bake a 24pt SVG into a blurry 24px file.
    static func normalizedPNG(from image: NSImage) -> Data? {
        let sourceLongEdge = pixelSize(of: image)
            .map { max($0.width, $0.height) } ?? maxDimension
        guard let target = fittedSize(for: image, longEdge: min(sourceLongEdge, maxDimension)),
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(target.width),
                pixelsHigh: Int(target.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              )
        else { return nil }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Up to an 8× reduction — the default interpolation aliases fine
        // detail. `AgentIconView` sets `.high` for its own draw for the same
        // reason.
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

struct AgentIconView: View {
    let asset: String?
    let fallbackSymbol: String
    let size: CGFloat

    var body: some View {
        Group {
            if let asset, let image = AgentIcon.nsImage(asset: asset) {
                styledIcon(image, monochrome: AgentIcon.isMonochrome(asset))
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
    }

    /// Mono marks (white-on-transparent lobe icons) template-render tinted with
    /// `Theme.chromeForeground` so they adapt per theme instead of vanishing on
    /// light chrome — reading that token also registers the theme observation so
    /// they re-flip on a theme switch. Color brands render `.original` and are
    /// left untinted, keeping their own pixels on every theme.
    @ViewBuilder
    private func styledIcon(_ image: NSImage, monochrome: Bool) -> some View {
        let img = Image(nsImage: image)
            .renderingMode(monochrome ? .template : .original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
        if monochrome {
            img.foregroundStyle(Theme.chromeForeground)
        } else {
            img
        }
    }
}
