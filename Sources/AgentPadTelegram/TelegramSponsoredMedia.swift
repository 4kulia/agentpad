import Foundation
import Darwin

/// Called exclusively on the connector actor, never on MainActor. Files are
/// copied by the filesystem, not materialized as Data, into a private LRU.
final class TelegramSponsoredDiskCache {
    struct Item { let url: URL; let size: Int64; var used: UInt64 }
    let root: URL
    let source: URL
    var items: [Int64: Item] = [:]
    var clock: UInt64 = 0
    var bytes: Int64 { items.values.reduce(0) { $0 + $1.size } }
    init(root: URL, source: URL) throws {
        self.root = root; self.source = source
        try TelegramProfileStore.validate(source, directory: true)
        try TelegramProfileStore.createDirectory(root)
        // Results aren't persistent. Remove only our own generated cache files.
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try TelegramProfileStore.validate(url, directory: false)
            try FileManager.default.removeItem(at: url)
        }
    }
    func url(_ id: Int64) -> URL? {
        guard var item = items[id], FileManager.default.fileExists(atPath: item.url.path) else { items[id] = nil; return nil }
        clock &+= 1; item.used = clock; items[id] = item; return item.url
    }
    func importFile(_ id: Int64, path: String, pinned: Set<Int64>) throws -> URL {
        if let url = url(id) { return url }
        let input = URL(fileURLWithPath: path)
        var ancestor = input
        while ancestor.path.hasPrefix(source.path + "/") {
            var info = stat()
            guard lstat(ancestor.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { throw TelegramConversationError.files }
            ancestor.deleteLastPathComponent()
        }
        guard input.path.hasPrefix(source.path + "/"), !input.pathComponents.contains(".."), !input.pathComponents.contains("."),
              let attributes = try? FileManager.default.attributesOfItem(atPath: input.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0, size <= TelegramSponsoredLimits.fileBytes else {
            throw TelegramConversationError.files
        }
        for (oldID, item) in items.sorted(by: { $0.value.used < $1.value.used }) where (bytes + size > TelegramSponsoredLimits.diskBytes || items.count >= 256) && !pinned.contains(oldID) {
            try FileManager.default.removeItem(at: item.url); items[oldID] = nil
        }
        guard bytes + size <= TelegramSponsoredLimits.diskBytes, items.count < 256 else { throw TelegramConversationError.files }
        let ext = ["jpg", "jpeg", "png", "webp", "gif", "mp4", "mov"].contains(input.pathExtension.lowercased()) ? input.pathExtension.lowercased() : "media"
        let target = root.appendingPathComponent(UUID().uuidString + "." + ext)
        do {
            try FileManager.default.copyItem(at: input, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try TelegramProfileStore.validate(target, directory: false)
            guard (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value == size else { throw TelegramConversationError.files }
        } catch { try? FileManager.default.removeItem(at: target); throw error }
        clock &+= 1; items[id] = Item(url: target, size: size, used: clock); return target
    }
    func clear() {
        for item in items.values { try? FileManager.default.removeItem(at: item.url) }
        items = [:]
    }
}

extension TelegramFeedSession {
    struct SponsoredDownload { let file: Int64; let chat: Int64; let result: UUID; var cancelling = false }
    var sponsoredDemand: [(Int64, TelegramSponsoredRef)] {
        sponsored.keys.sorted().flatMap { chat -> [(Int64, TelegramSponsoredRef)] in
            guard sponsoredShown(chat), let entry = sponsored[chat], entry.snapshot.expiresAt.map({ now < $0 }) == true else { return [] }
            let requested = Set(feeds(in: chat).flatMap { $0.observations.values }.filter(\.shown).flatMap(\.sponsoredRequests))
            return entry.snapshot.messages.filter { requested.contains($0.ref) }.map { (chat, $0.ref) }
        }
    }
    func reconcileSponsoredDownloads() {
        let demand = sponsoredDemand
        let pinned = Set(demand.flatMap { chat, ref in sponsored[chat]?.snapshot.messages.first { $0.ref == ref }?.media.map(\.id) ?? [] })
        if let current = sponsoredDownload, !pinned.contains(current.file) { cancelSponsoredDownload() }
        if let file = sponsoredDeletions.min(), now >= sponsoredDeleteRetryAt {
            let ordinary = downloads[file] != nil || feeds.values.contains { $0.snapshot.messages.contains { $0.attachment?.id == file } }
            if ordinary { sponsoredDeletions.remove(file) }
            else {
                _ = request("deleteFile", ["file_id": .integer(file)], localControl: true) { [weak self] response in
                    guard let self else { return }
                    if response.type == "ok" { self.sponsoredDeletions.remove(file) }
                    else { self.sponsoredDeleteRetryAt = self.now.addingTimeInterval(4) }
                }
            }
        }
        var queue: [(Int64, TelegramSponsoredRef, TelegramSponsoredMedia)] = []
        var seen = Set<Int64>()
        for (chat, ref) in demand {
            guard let entry = sponsored[chat], let index = entry.snapshot.messages.firstIndex(where: { $0.ref == ref }), entry.snapshot.messages[index].error == nil else { continue }
            resolveSponsoredBackground(chat, entry: entry, ref: ref)
            for i in entry.snapshot.messages[index].media.indices {
                var media = entry.snapshot.messages[index].media[i]
                if let cached = sponsoredDisk?.url(media.id) { media.url = cached }
                else { media.url = nil }
                entry.snapshot.messages[index].media[i] = media
                if media.url == nil, media.error == nil, queue.count < TelegramSponsoredLimits.queue, seen.insert(media.id).inserted { queue.append((chat, ref, media)) }
            }
            publishSponsored(chat)
        }
        guard sponsoredDownload == nil, downloads.count < 2, network == .ready, sponsoredDeletions.count < 256 else { return }
        for (chat, ref, media) in queue {
            guard let entry = sponsored[chat], let raw = entry.files[media.id] else { continue }
            if raw["local"]?.object?["is_downloading_completed"]?.bool == true {
                finishSponsoredFile(raw, pinned: pinned); continue
            }
            guard media.size <= TelegramSponsoredLimits.fileBytes, media.width > 0, media.height > 0,
                  media.width <= 8192, media.height <= 8192, media.width * media.height <= TelegramSponsoredLimits.pixels else {
                sponsoredFileError(media.id, "Ad media exceeds the supported resource budget"); continue
            }
            sponsoredDownload = .init(file: media.id, chat: chat, result: ref.result)
            let sent = request("downloadFile", ["file_id": .integer(media.id), "priority": .integer(16), "offset": .integer(0), "limit": .integer(0), "synchronous": .bool(false)],
                onTimeout: { [weak self] in self?.sponsoredFileError(media.id, "Ad download timed out · Retry"); self?.cancelSponsoredDownload() }) { [weak self] response in
                guard let self, !self.stopped else { return }
                if response.type == "file" { self.applySponsoredFile(response) }
                else {
                    self.sponsoredFileError(media.id, "Ad download failed · Retry")
                    if self.sponsoredDownload?.file == media.id { self.sponsoredDownload = nil }
                }
            }
            if !sent { sponsoredDownload = nil }
            break
        }
    }
    func applySponsoredFile(_ raw: TDLibMessage) {
        guard let file = raw["id"]?.integer else { return }
        for entry in sponsored.values where entry.files[file] != nil { entry.files[file] = raw }
        guard sponsoredDownload?.file == file else { return }
        let size = max(raw["size"]?.integer ?? 0, raw["local"]?.object?["downloaded_size"]?.integer ?? 0)
        if size > TelegramSponsoredLimits.fileBytes {
            sponsoredFileError(file, "Ad media exceeds 50 MiB"); cancelSponsoredDownload(); return
        }
        if raw["local"]?.object?["is_downloading_completed"]?.bool == true {
            let pins = Set(sponsoredDemand.flatMap { chat, ref in sponsored[chat]?.snapshot.messages.first { $0.ref == ref }?.media.map(\.id) ?? [] })
            if pins.contains(file) { finishSponsoredFile(raw, pinned: pins) }
            sponsoredDownload = nil
        } else if raw["local"]?.object?["is_downloading_active"]?.bool == false {
            sponsoredFileError(file, "Ad download stopped · Retry"); sponsoredDownload = nil
        }
    }
    func finishSponsoredFile(_ raw: TDLibMessage, pinned: Set<Int64>) {
        guard let file = raw["id"]?.integer else { return }
        do {
            guard let disk = sponsoredDisk, let path = raw["local"]?.object?["path"]?.string else { throw TelegramConversationError.files }
            let url = try disk.importFile(file, path: path, pinned: pinned)
            for (chat, entry) in sponsored {
                for i in entry.snapshot.messages.indices {
                    for j in entry.snapshot.messages[i].media.indices where entry.snapshot.messages[i].media[j].id == file {
                        if entry.snapshot.messages[i].media[j].error == nil { entry.snapshot.messages[i].media[j].url = url }
                    }
                }
                publishSponsored(chat)
            }
            // TDLib's general cache is not a second sponsored cache. Never delete
            // a file currently used by the ordinary attachment path.
            if downloads[file] == nil && !feeds.values.contains(where: { $0.snapshot.messages.contains { $0.attachment?.id == file } }) {
                sponsoredDeletions.insert(file)
            }
        } catch { sponsoredFileError(file, "Ad media unavailable · Retry") }
    }
    func sponsoredFileError(_ id: Int64, _ error: String) {
        for (chat, entry) in sponsored {
            for i in entry.snapshot.messages.indices {
                for j in entry.snapshot.messages[i].media.indices where entry.snapshot.messages[i].media[j].id == id {
                    entry.snapshot.messages[i].media[j].error = error; entry.snapshot.messages[i].media[j].url = nil
                }
            }
            publishSponsored(chat)
        }
    }
    func cancelSponsoredDownload() {
        guard var current = sponsoredDownload, !current.cancelling else { return }
        current.cancelling = true; sponsoredDownload = current
        if !request("cancelDownloadFile", ["file_id": .integer(current.file), "only_if_pending": .bool(false)], localControl: true, { [weak self] response in
            guard let self, self.sponsoredDownload?.file == current.file else { return }
            if response.type == "ok" { self.sponsoredDownload = nil }
            else { self.sponsoredDownload?.cancelling = false }
        }) { sponsoredDownload?.cancelling = false }
    }
    func cancelSponsoredMedia(_ id: TelegramChatID, epoch: UUID, ref: TelegramSponsoredRef) {
        guard let (_, message) = currentSponsored(id, epoch: epoch, ref: ref) else { return }
        for media in message.media {
            sponsoredFileError(media.id, "Ad download cancelled · Retry")
            if sponsoredDownload?.file == media.id { cancelSponsoredDownload() }
        }
    }
    func resolveSponsoredBackground(_ chat: Int64, entry: SponsoredEntry, ref: TelegramSponsoredRef) {
        guard let message = entry.snapshot.messages.first(where: { $0.ref == ref }), !message.backgroundResolved,
              !entry.backgroundPending.contains(ref.message) else { return }
        entry.backgroundPending.insert(ref.message)
        let sent = request("getCustomEmojiStickers", ["custom_emoji_ids": .array([.integer(message.backgroundEmojiID)])]) { [weak self, weak entry] response in
            guard let self, let entry, entry.snapshot.result == ref.result,
                  let i = entry.snapshot.messages.firstIndex(where: { $0.ref == ref }) else { return }
            entry.backgroundPending.remove(ref.message)
            let sticker = response["stickers"]?.array.first?.object
            // A static thumbnail is sufficient for the repeated background motif;
            // never run another animation/player behind the sponsored content.
            let thumbnail = sticker?["thumbnail"]?.object
            let file = thumbnail?["file"]?.object ?? (sticker?["format"]?.object?.type == "stickerFormatWebp" ? sticker?["sticker"]?.object : nil)
            let dimensions = thumbnail ?? sticker
            if let file, let media = TelegramSponsoredDecoder.media(file, kind: .photo, role: .background,
                width: Int(dimensions?["width"]?.integer ?? 0), height: Int(dimensions?["height"]?.integer ?? 0)) {
                entry.snapshot.messages[i].media.append(media); entry.files[media.id] = file
                entry.snapshot.messages[i].backgroundResolved = true
            } else { entry.snapshot.messages[i].error = "Ad background unavailable · Retry" }
            self.publishSponsored(chat)
        }
        if !sent { entry.backgroundPending.remove(ref.message) }
    }
}
