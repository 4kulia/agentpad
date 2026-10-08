import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One shared executor bounds expensive image decoding/encoding to one job.
/// No AppKit objects or database/UI state cross into this worker.
actor ChatAttachmentWorker {
    static let shared = ChatAttachmentWorker()
    enum Input: Sendable {
        case file(URL)
        case clipboard(Data)
    }
    struct Prepared: Sendable {
        let data: Data
        let file: ChatAttachment
        let digest: String
        let thumbnail: CGImage?
    }
    func prepare(_ input: Input, limits: ChatAttachmentLimits) throws -> Prepared {
        try Task.checkCancellation()
        var data: Data, name: String
        switch input {
        case .file(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            (data, name) = try Self.sanitizedFile(ChatAttachmentStorage.read(url, limit: limits.fileBytes),
                name: url.lastPathComponent, limits: limits)
        case .clipboard(let bytes):
            (data, name) = try Self.convertedImage(bytes, name: "Clipboard", limits: limits)
        }
        try Task.checkCancellation()
        let file = try ChatAttachmentStorage.descriptor(data: data, name: name, limits: limits)
        return Prepared(data: data, file: file, digest: ChatAttachments.digest(data), thumbnail: file.isImage ? thumbnail(data) : nil)
    }
    /// Both queued imports and the legacy synchronous file path must sanitize
    /// server-native PNG/JPEG too, before saving, hashing or uploading bytes.
    nonisolated static func sanitizedFile(_ bytes: Data, name: String, limits: ChatAttachmentLimits) throws -> (Data, String) {
        guard ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif"].contains((name as NSString).pathExtension.lowercased()) else {
            return (bytes, name)
        }
        return try convertedImage(bytes, name: name, limits: limits)
    }
    /// Rebuild from oriented pixels, never from source metadata. The server's
    /// PNG/JPEG contract cannot preserve animation, so reject animated GIFs.
    /// Check dimensions before decoding and encoded byte quotas afterward.
    private nonisolated static func convertedImage(_ bytes: Data, name: String, limits: ChatAttachmentLimits) throws -> (Data, String) {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png, .jpeg, .heic, .heif, .tiff, .gif].contains(where: { $0.identifier == type }) else { throw ChatAttachmentError.type }
        if type == UTType.gif.identifier, CGImageSourceGetCount(source) > 1 { throw ChatAttachmentError.animatedGIF }
        guard CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= limits.imageSide, h <= limits.imageSide, w <= limits.imagePixels / h else { throw ChatAttachmentError.type }
        let outputType: UTType, ext: String
        let jpeg = [(name as NSString).pathExtension.lowercased(), "jpg", "jpeg"].first {
            ["jpg", "jpeg"].contains($0) && limits.extensions.contains($0) && limits.mimeTypes.contains("image/jpeg")
        }
        // Keep photographs compressed as JPEG, but never keep the source bytes.
        if type == UTType.jpeg.identifier, let jpeg {
            outputType = .jpeg; ext = jpeg
        } else if limits.extensions.contains("png"), limits.mimeTypes.contains("image/png") {
            outputType = .png; ext = "png"
        } else if let jpeg {
            outputType = .jpeg; ext = jpeg
        } else { throw ChatAttachmentError.type }
        try Task.checkCancellation()
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
        ] as CFDictionary) else { throw ChatAttachmentError.type }
        try Task.checkCancellation()
        let encoded = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(encoded, outputType.identifier as CFString, 1, nil) else { throw ChatAttachmentError.type }
        CGImageDestinationAddImage(output, decoded, nil)
        guard CGImageDestinationFinalize(output) else { throw ChatAttachmentError.type }
        try Task.checkCancellation()
        let outputName = (name as NSString).deletingPathExtension + "." + ext
        // ImageIO synthesizes technical EXIF even with nil properties. Remove
        // it losslessly from our new image without encoding the pixels again.
        if outputType == .png { return (try strippedPNG(encoded as Data), outputName) }
        let stripped = NSMutableData()
        guard let encodedSource = CGImageSourceCreateWithData(encoded, [kCGImageSourceShouldCache: false] as CFDictionary),
              let destination = CGImageDestinationCreateWithData(stripped, outputType.identifier as CFString, 1, nil),
              CGImageDestinationCopyImageSource(destination, encodedSource, [
                kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
                kCGImageMetadataShouldExcludeXMP: true,
              ] as CFDictionary, nil) else { throw ChatAttachmentError.type }
        return (stripped as Data, outputName)
    }
    /// CopyImageSource writes an empty XMP packet for PNG even with exclude-XMP.
    /// Remove ancillary metadata chunks from our own encoded PNG instead. Keep
    /// image/color chunks and their CRCs intact; never parse the original here.
    private nonisolated static func strippedPNG(_ bytes: Data) throws -> Data {
        let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
        guard bytes.starts(with: signature) else { throw ChatAttachmentError.type }
        var result = signature, offset = signature.count
        while offset < bytes.count {
            guard bytes.count - offset >= 12 else { throw ChatAttachmentError.type }
            let length = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= bytes.count - offset - 12 else { throw ChatAttachmentError.type }
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            let end = offset + length + 12
            if !["eXIf", "iTXt", "tEXt", "zTXt"].contains(type) { result.append(bytes[offset..<end]) }
            offset = end
        }
        return result
    }
    func thumbnail(at url: URL, limit: Int) throws -> CGImage? {
        try Task.checkCancellation()
        return thumbnail(try ChatAttachmentStorage.read(url, limit: limit))
    }
    private func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 84,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}
