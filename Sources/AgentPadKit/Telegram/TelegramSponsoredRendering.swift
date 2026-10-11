import AgentPadTelegram
import AppKit
import AVFoundation
import ImageIO
import Observation
import UniformTypeIdentifiers

struct TelegramSponsoredAsset: @unchecked Sendable {
    let image: CGImage
    let movie: AVURLAsset?
    let hasAudio: Bool
    let frames: Int
    let delay: TimeInterval
    var bytes: Int { image.bytesPerRow * image.height }
}

/// One decode at a time, including GIF frames. URL-backed ImageIO/AVFoundation
/// avoid reading whole files into Data or retaining every animation frame.
actor TelegramSponsoredImageDecoder {
    static let shared = TelegramSponsoredImageDecoder()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private func lock() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }
    private func unlock() { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
    func decode(_ url: URL, kind: TelegramSponsoredMedia.Kind, frame: Int = 0) async throws -> TelegramSponsoredAsset {
        await lock(); defer { unlock() }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 50 * 1024 * 1024 else { throw TelegramConversationError.files }
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true, CGImageSourceGetCount(source) > 0 {
            let count = CGImageSourceGetCount(source)
            guard count > 0, frame < count, let properties = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_000_000,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, frame, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1280] as CFDictionary) else { throw TelegramConversationError.files }
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            return .init(image: image, movie: nil, hasAudio: false, frames: count, delay: max(0.04, delay))
        }
        guard kind != .photo else { throw TelegramConversationError.files }
        let movie = AVURLAsset(url: url)
        guard try await movie.load(.isPlayable), let track = try await movie.loadTracks(withMediaType: .video).first else { throw TelegramConversationError.files }
        let dimensions = try await track.load(.naturalSize)
        guard dimensions.width > 0, dimensions.height > 0, dimensions.width <= 8192, dimensions.height <= 8192, dimensions.width * dimensions.height <= 16_000_000 else { throw TelegramConversationError.files }
        let generator = AVAssetImageGenerator(asset: movie)
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 1280, height: 1280)
        let image = try await generator.image(at: .zero).image
        let audio = try await !movie.loadTracks(withMediaType: .audio).isEmpty
        return .init(image: image, movie: movie, hasAudio: audio, frames: 1, delay: 0)
    }
}

@MainActor @Observable final class TelegramSponsoredRenderCache {
    static let shared = TelegramSponsoredRenderCache()
    private(set) var assets: [URL: TelegramSponsoredAsset] = [:]
    private(set) var errors: [URL: String] = [:]
    @ObservationIgnored private var leases: [UUID: [TelegramSponsoredMedia]] = [:]
    @ObservationIgnored private var queue: [TelegramSponsoredMedia] = []
    @ObservationIgnored private var running: URL?
    @ObservationIgnored private var generation = UUID()
    // Reserve half the 64 MiB decoded budget for the single player/frame path.
    static let imageBudget = 32 * 1024 * 1024
    var decodedBytes: Int { assets.values.reduce(0) { $0 + $1.bytes } }
    func retain(_ owner: UUID, media: [TelegramSponsoredMedia]) {
        leases[owner] = media
        let retained = Set(leases.values.flatMap { $0.compactMap(\.url) })
        assets = assets.filter { retained.contains($0.key) }; errors = errors.filter { retained.contains($0.key) }
        pump()
    }
    func release(_ owner: UUID) {
        leases[owner] = nil
        let retained = Set(leases.values.flatMap { $0.compactMap(\.url) })
        assets = assets.filter { retained.contains($0.key) }; errors = errors.filter { retained.contains($0.key) }
        if leases.isEmpty { generation = UUID(); queue = [] }
        TelegramSponsoredPlayback.shared.stop(owner: owner)
    }
    func retry(_ media: [TelegramSponsoredMedia]) {
        for url in media.compactMap(\.url) { errors[url] = nil }
        pump()
    }
    private func pump() {
        var seen = Set<URL>()
        queue = Array(leases.values.flatMap { $0 }.filter {
            guard let url = $0.url else { return false }
            return assets[url] == nil && errors[url] == nil && running != url && seen.insert(url).inserted
        }.prefix(8))
        guard running == nil, !queue.isEmpty, let url = queue[0].url else { return }
        let media = queue.removeFirst(), generation = generation
        running = url
        Task {
            let result: Result<TelegramSponsoredAsset, Error>
            do { result = .success(try await TelegramSponsoredImageDecoder.shared.decode(url, kind: media.kind)) }
            catch { result = .failure(error) }
            running = nil
            if self.generation == generation, leases.values.contains(where: { $0.contains { $0.url == url } }) {
                switch result {
                case .success(let asset):
                    if decodedBytes + asset.bytes <= Self.imageBudget { assets[url] = asset }
                    else { errors[url] = "Ad preview exceeds the available media budget · Retry" }
                case .failure: errors[url] = "Ad media could not be displayed · Retry"
                }
            }
            pump()
        }
    }
}

@MainActor @Observable final class TelegramSponsoredPlayback {
    static let shared = TelegramSponsoredPlayback()
    private(set) var owner: UUID?
    private(set) var player: AVPlayer?
    private(set) var frame: CGImage?
    @ObservationIgnored private var animation: Task<Void, Never>?
    @ObservationIgnored private var loop: NSObjectProtocol?
    func play(owner: UUID, asset: TelegramSponsoredAsset, url: URL, muted: Bool) {
        stop(); self.owner = owner
        if let movie = asset.movie {
            let item = AVPlayerItem(asset: movie)
            item.preferredMaximumResolution = CGSize(width: 1280, height: 720)
            item.preferredForwardBufferDuration = 1
            item.preferredPeakBitRate = 4_000_000
            let player = AVPlayer(playerItem: item); player.isMuted = muted; self.player = player
            if muted {
                loop = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak player] _ in
                    MainActor.assumeIsolated { player?.seek(to: .zero); player?.play() }
                }
            }
            player.play()
        } else if asset.frames > 1 {
            frame = asset.image
            animation = Task {
                var delay = asset.delay, index = 1
                while !Task.isCancelled, self.owner == owner {
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { break }
                    do {
                        let next = try await TelegramSponsoredImageDecoder.shared.decode(url, kind: .animation, frame: index)
                        guard !Task.isCancelled, self.owner == owner else { break }
                        frame = next.image; delay = next.delay; index = (index + 1) % asset.frames
                    } catch { break }
                }
            }
        }
    }
    func stop(owner: UUID? = nil) {
        guard owner == nil || owner == self.owner else { return }
        animation?.cancel(); animation = nil; player?.pause(); player?.replaceCurrentItem(with: nil); player = nil; frame = nil; self.owner = nil
        if let loop { NotificationCenter.default.removeObserver(loop) }; loop = nil
    }
}
