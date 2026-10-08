import Foundation

/// All replacement tests keep their Trash inside the fixture directory.
final class TestTransferFileManager: FileManager, @unchecked Sendable {
    let trashDirectory: URL
    var afterCopy: ((URL, URL) throws -> Void)?
    var events: [String] = []
    var trashed: [URL] = []
    init(trashDirectory: URL) { self.trashDirectory = trashDirectory; super.init() }
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try super.copyItem(at: srcURL, to: dstURL)
        events.append("copy")
        try afterCopy?(srcURL, dstURL)
    }
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try super.moveItem(at: srcURL, to: dstURL)
        events.append("move")
    }
    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        try createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let destination = trashDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try super.moveItem(at: url, to: destination)
        events.append("trash"); trashed.append(destination)
        outResultingURL?.pointee = destination as NSURL
    }
}
