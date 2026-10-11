import Foundation

extension TelegramFeedSession {
    func configureCache() {
        guard now >= cacheRetryAt else { return }
        let requestedLimit = journal.cacheLimitMiB
        let values: [(String, TDLibValue)] = [
            ("storage_max_files_size", .typed("optionValueInteger", ["value": .integer(Int64(requestedLimit) * 1024)])),
            ("use_storage_optimizer", .typed("optionValueBoolean", ["value": .bool(true)]))
        ]
        for (name, value) in values where !cacheOptions.contains(name) && !pendingCacheOptions.contains(name) {
            if request("setOption", ["name": .string(name), "value": value], { [weak self] result in
                guard let self else { return }; self.pendingCacheOptions.remove(name)
                if result.type == "ok" {
                    if name != "storage_max_files_size" || self.journal.cacheLimitMiB == requestedLimit { self.cacheOptions.insert(name) }
                }
                else { self.cacheRetryAt = self.now.addingTimeInterval(60) }
            }) { pendingCacheOptions.insert(name) }
        }
    }
    func setCacheLimit(_ limit: Int) {
        do {
            try journal.setCacheLimit(limit); cacheOptions.remove("storage_max_files_size")
            for feed in feeds.values { feed.dirty = true }
        } catch { for feed in feeds.values { problem(feed, "Download cache settings could not be saved.") } }
    }
    func clearCache() {
        let pendingChats = Set(journal.operations.filter { $0.parts.contains { [.submitting, .pending, .unknown].contains($0.state) } }.map(\.chat))
        _ = request("optimizeStorage", ["size": .integer(0), "ttl": .integer(-1), "count": .integer(-1), "immunity_delay": .integer(0),
            "file_types": .array([.typed("fileTypePhoto"), .typed("fileTypeDocument")]), "chat_ids": .array([]),
            "exclude_chat_ids": .array(pendingChats.map(TDLibValue.integer)), "return_deleted_file_statistics": .bool(true), "chat_limit": .integer(0)]) { [weak self] result in
                guard let self else { return }
                if result.type == "error" { for feed in self.feeds.values { self.problem(feed, "Download cache could not be cleared. Try again.") } }
            }
    }
    func stage(_ id: TelegramChatID, epoch: UUID, data: Data, name: String, mime: String, width: Int, height: Int) throws -> TelegramStagedAttachment {
        guard matches(id, epoch), let feed = feeds[id], feed.snapshot.capabilities.canSend else { throw TelegramConversationError.unavailable }
        guard width >= 0, height >= 0, width <= 8192, height <= 8192, width * height <= 32 * 1024 * 1024 else { throw TelegramConversationError.files }
        return try journal.stage(data, name: name, mime: mime, width: width, height: height)
    }
    func download(_ id: TelegramChatID, epoch: UUID, messageID: Int64, cancel: Bool) {
        guard matches(id, epoch), let feed = feeds[id], feed.snapshot.capabilities.canRead,
              let message = feed.snapshot.messages.first(where: { $0.messageID == messageID }), !message.protectedContent,
              let file = message.attachment else { return }
        if cancel {
            if request("cancelDownloadFile", ["file_id": .integer(file.id), "only_if_pending": .bool(false)]) { downloads[file.id] = nil }
            return
        }
        guard downloads.count + (sponsoredDownload == nil ? 0 : 1) < 2 || downloads[file.id] != nil, downloads[file.id] == nil,
              file.size <= TelegramFeedLimits.fileBytes,
              ["image/png", "image/jpeg", "application/pdf", "text/plain", "application/json"].contains(file.mime) else {
            problem(feed, "Download unavailable. Use a supported file up to 20 MiB, with at most two downloads at once."); return
        }
        if request("downloadFile", ["file_id": .integer(file.id), "priority": .integer(16), "offset": .integer(0),
            "limit": .integer(0), "synchronous": .bool(false)], { [weak self, weak feed] response in
                guard let self, let feed else { return }
                if response.type == "file" { self.applyFile(response) }
                else { self.downloads[file.id] = nil; self.problem(feed, "Download failed. Try Download again.") }
            }) { downloads[file.id] = id.chat }
    }
    func applyFile(_ raw: TDLibMessage) {
        guard let id = raw["id"]?.integer else { return }
        applySponsoredFile(raw)
        let local = raw["local"]?.object
        for feed in feeds.values {
            for i in feed.snapshot.messages.indices where feed.snapshot.messages[i].attachment?.id == id {
                TelegramMessageDecoder.updateFile(&feed.snapshot.messages[i].attachment!, raw); feed.dirty = true
            }
        }
        if downloads[id] != nil {
            if (raw["size"]?.integer ?? 0) > TelegramFeedLimits.fileBytes || (local?["downloaded_size"]?.integer ?? 0) > TelegramFeedLimits.fileBytes {
                _ = request("cancelDownloadFile", ["file_id": .integer(id), "only_if_pending": .bool(false)])
                downloads[id] = nil; filePaths[id] = nil
            } else if local?["is_downloading_completed"]?.bool == true, let path = local?["path"]?.string {
                filePaths[id] = path; downloads[id] = nil
            }
        }
        let retained = Set(feeds.values.flatMap { $0.snapshot.messages.compactMap { $0.attachment?.id } })
        filePaths = filePaths.filter { retained.contains($0.key) }
    }
    func attachmentURL(_ id: TelegramChatID, epoch: UUID, messageID: Int64, filesRoot: URL) throws -> URL {
        guard matches(id, epoch), let feed = feeds[id], feed.snapshot.capabilities.canRead,
              feed.chat?["has_protected_content"]?.bool != true,
              let message = feed.snapshot.messages.first(where: { $0.messageID == messageID }), !message.protectedContent,
              message.expiresAt.map({ now < $0 }) ?? true, let file = message.attachment, file.complete,
              let path = filePaths[file.id] else { throw TelegramConversationError.unavailable }
        let url = URL(fileURLWithPath: path)
        guard url.resolvingSymlinksInPath().path == url.path, url.path.hasPrefix(filesRoot.path + "/"),
              let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]).fileSize,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              size > 0, size <= TelegramFeedLimits.fileBytes, Int64(size) == file.size else { throw TelegramConversationError.files }
        return url
    }
}
