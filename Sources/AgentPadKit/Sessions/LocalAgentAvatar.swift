import AppKit
import ImageIO
import UniformTypeIdentifiers

enum LocalAvatarError: Error, LocalizedError, Equatable {
    case format, size, damaged, changed
    var errorDescription: String? {
        switch self {
        case .format: "Choose a still JPG or PNG image."
        case .size: "Choose an image up to 10 MB, 20 million pixels, and 10,000 pixels per side."
        case .damaged: "This image could not be read. Choose another file."
        case .changed: "This avatar changed in another editor. Reload before saving."
        }
    }
}

struct AvatarCrop: Equatable, Sendable {
    var x = 0.5
    var y = 0.5
    var zoom = 1.0
    func rect(width: Int, height: Int) -> CGRect {
        let side = Double(min(width, height)) / min(3, max(1, zoom.isFinite ? zoom : 1))
        return CGRect(x: (Double(width) - side) * min(1, max(0, x.isFinite ? x : 0.5)),
                      y: (Double(height) - side) * min(1, max(0, y.isFinite ? y : 0.5)), width: side, height: side)
    }
}

/// Bounded ImageIO decoding and fresh pixel encoding, with no source metadata.
enum LocalAvatarImage {
    static let byteLimit = 10 * 1024 * 1024
    static let outputLimit = 2 * 1024 * 1024

    static func read(_ url: URL) throws -> CGImage {
        guard url.isFileURL else { throw LocalAvatarError.format }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw LocalAvatarError.format }
        guard let size = values.fileSize, size <= byteLimit else { throw LocalAvatarError.size }
        // Bound the actual read as well as the stat (the file may change).
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try decode(handle.read(upToCount: byteLimit + 1) ?? Data())
    }

    static func decode(_ data: Data) throws -> CGImage {
        guard data.count <= byteLimit else { throw LocalAvatarError.size }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, [UTType.jpeg.identifier, UTType.png.identifier].contains(type),
              CGImageSourceGetCount(source) == 1 else { throw LocalAvatarError.format }
        if type == UTType.png.identifier {
            // Reject APNG even on OS versions whose ImageIO exposes just frame 0.
            var offset = 8
            let bytes = [UInt8](data)
            while offset + 12 <= bytes.count {
                let length = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
                guard length <= bytes.count - offset - 12 else { throw LocalAvatarError.damaged }
                if String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii) == "acTL" { throw LocalAvatarError.format }
                offset += length + 12
            }
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw LocalAvatarError.damaged }
        guard width <= 10_000, height <= 10_000, width * height <= 20_000_000 else { throw LocalAvatarError.size }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary), CGImageSourceGetStatus(source) == .statusComplete else { throw LocalAvatarError.damaged }
        return image
    }

    static func png(_ image: CGImage, crop: AvatarCrop, side: Int = 512) throws -> Data {
        guard (1...512).contains(side) else { throw LocalAvatarError.size }
        guard let cropped = image.cropping(to: crop.rect(width: image.width, height: image.height)),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw LocalAvatarError.damaged }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        let data = NSMutableData()
        guard let pixels = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw LocalAvatarError.damaged }
        CGImageDestinationAddImage(destination, pixels, nil)
        guard CGImageDestinationFinalize(destination), data.length <= outputLimit else { throw LocalAvatarError.size }
        // ImageIO may synthesize an eXIf chunk even for a fresh CGContext.
        // Keep only the pixel/color chunks; never carry text, EXIF or XMP.
        let bytes = [UInt8](data as Data)
        var clean = Data(bytes.prefix(8)), offset = 8
        let allowed = Set(["IHDR", "IDAT", "IEND", "sRGB", "iCCP", "gAMA", "cHRM"])
        while offset + 12 <= bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= bytes.count - offset - 12 else { throw LocalAvatarError.damaged }
            let end = offset + length + 12
            if let type = String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii), allowed.contains(type) {
                clean.append(contentsOf: bytes[offset..<end])
            }
            offset = end
        }
        return clean
    }
}

extension AgentProfileDetailsStore {
    func avatar(_ id: UUID) -> Avatar { archive.avatars[id] ?? Avatar() }

    func avatarURL(_ id: UUID) -> URL? {
        guard let name = avatar(id).file, UUID(uuidString: String(name.dropLast(4))) != nil, name.hasSuffix(".png") else { return nil }
        return fileURL?.deletingLastPathComponent().appendingPathComponent("profile-assets/\(id.uuidString)/\(name)")
    }

    /// File first, reference second. A failed commit leaves the old image live.
    func saveAvatar(_ data: Data?, for id: UUID, expectedRevision: Int) throws {
        try checkReadable()
        defer { cleanupAvatars() }
        guard avatar(id).revision == expectedRevision else { throw LocalAvatarError.changed }
        var next = archive
        let filename = data.map { _ in "\(UUID().uuidString).png" }
        if let data {
            guard data.count <= LocalAvatarImage.outputLimit,
                  let image = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(image) as String? == UTType.png.identifier else { throw LocalAvatarError.format }
            guard let root = fileURL?.deletingLastPathComponent(), let filename else { throw CocoaError(.fileWriteUnknown) }
            let target = root.appendingPathComponent("profile-assets/\(id.uuidString)/\(filename)")
            let clean = try LocalAvatarImage.png(LocalAvatarImage.decode(data), crop: AvatarCrop())
            try Self.writePrivate(clean, target)
        }
        next.avatars[id] = Avatar(revision: expectedRevision + 1, file: filename)
        try commit(next)
    }
}


extension AgentProfileDetailsStore {
    func image(_ id: UUID) -> NSImage? {
        let revision = avatar(id).revision
        if let cached = avatarImages[id], cached.0 == revision { return cached.1 }
        let image = avatarURL(id).flatMap { url -> NSImage? in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= LocalAvatarImage.outputLimit, let bytes = try? Data(contentsOf: url) else { return nil }
            return NSImage(data: bytes)
        }
        avatarImages[id] = (revision, image)
        return image
    }
}
