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
        let data: Data, name: String
        switch input {
        case .file(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            data = try ChatAttachmentStorage.read(url, limit: limits.fileBytes)
            name = url.lastPathComponent
        case .clipboard(let bytes):
            guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0, w <= limits.imageSide, h <= limits.imageSide, w <= limits.imagePixels / h,
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ChatAttachmentError.type }
            try Task.checkCancellation()
            let png = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { throw ChatAttachmentError.type }
            CGImageDestinationAddImage(output, decoded, nil)
            guard CGImageDestinationFinalize(output) else { throw ChatAttachmentError.type }
            data = png as Data; name = "Clipboard.png"
        }
        try Task.checkCancellation()
        let file = try ChatAttachmentStorage.descriptor(data: data, name: name, limits: limits)
        return Prepared(data: data, file: file, digest: ChatAttachments.digest(data), thumbnail: file.isImage ? thumbnail(data) : nil)
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
