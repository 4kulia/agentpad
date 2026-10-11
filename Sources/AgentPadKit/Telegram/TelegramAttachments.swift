import AgentPadTelegram
import AppKit
import UniformTypeIdentifiers

extension ChatAttachmentLimits {
    static let telegram = ChatAttachmentLimits(fileBytes: 20 * 1024 * 1024, messageFiles: 10, messageBytes: 50 * 1024 * 1024,
        pendingFiles: 20, pendingBytes: 100 * 1024 * 1024, uploadsPerAccount: 2, downloadsPerAccount: 2, uploadRequestSeconds: 60,
        imagePixels: 32 * 1024 * 1024, imageSide: 8192, previewSide: 8192, previewBytes: 32 * 1024 * 1024,
        draftTTLSeconds: 7 * 86400, contextFiles: 10, contextBytes: 50 * 1024 * 1024,
        extensions: ["png", "jpg", "jpeg", "pdf", "txt", "md", "csv", "log", "json"],
        mimeTypes: ["image/png", "image/jpeg", "application/pdf", "text/plain", "application/json"], verification: "local")
}

/// Uses the same descriptor/FD validation and single image decoder as AgentPad
/// chat, with a TDLib backend. No org uploader, HTTP request or server outbox.
extension TelegramConversationModel: ConversationAttachmentBackend {
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .heic, .heif, .tiff, .gif, .pdf, .plainText, .json]
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.importFiles(panel.urls.map(ChatAttachmentWorker.Input.file))
        }
    }
    func paste(_ pasteboard: NSPasteboard, fromDrop: Bool = false) -> Bool {
        if pasteboard.availableType(from: [.fileURL]) != nil {
            guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
            importFiles(urls.map(ChatAttachmentWorker.Input.file)); return true
        }
        if fromDrop, let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            guard !importing, receivers.reduce(0, { $0 + max(1, $1.fileTypes.count) }) + draft.attachments.count <= 10,
                  let directory = importDirectory, let provider else {
                problem = "File drop is not ready or exceeds the attachment limit. Try again."; return true
            }
            let promises = ChatAttachmentFilePromises(receivers, directory: directory)
            do { try promises.start(directoryReady: true) }
            catch { problem = error.localizedDescription; return true }
            importing = true; importDirectory = nil
            let epoch = snapshot.epoch
            Task {
                do {
                    let inputs = try await promises.receive()
                    guard snapshot.epoch == epoch else { throw TelegramConversationError.unavailable }
                    importing = false
                    await prepareFiles(inputs)
                } catch { problem = error.localizedDescription; importing = false }
                await provider.removeAttachmentImportDirectory(id, epoch: epoch, directory: directory)
                prepareImportDirectory()
            }
            return true
        }
        if let bytes = ChatAttachmentPaste.imageTypes.lazy.compactMap({ pasteboard.data(forType: $0) }).first {
            importFiles([.clipboard(bytes)]); return true
        }
        return false
    }
    func prepareImportDirectory() {
        guard !preparingDirectory, importDirectory == nil, let provider else { return }
        preparingDirectory = true
        let epoch = snapshot.epoch
        Task {
            defer { preparingDirectory = false }
            if let directory = try? await provider.attachmentImportDirectory(id, epoch: epoch) {
                if snapshot.epoch == epoch { importDirectory = directory }
                else { await provider.removeAttachmentImportDirectory(id, epoch: epoch, directory: directory) }
            }
        }
    }
    func importFiles(_ inputs: [ChatAttachmentWorker.Input]) {
        Task { await prepareFiles(inputs) }
    }
    private func prepareFiles(_ inputs: [ChatAttachmentWorker.Input]) async {
        guard !importing, let provider, snapshot.capabilities.canSend else { return }
        guard !inputs.isEmpty, inputs.count + draft.attachments.count <= 10 else { problem = TelegramConversationError.files.rawValue; return }
        importing = true; problem = nil
        let epoch = snapshot.epoch
            var staged: [TelegramStagedAttachment] = []
            do {
                for input in inputs {
                    let result = try await ChatAttachmentWorker.shared.prepare(input, limits: .telegram)
                    guard snapshot.epoch == epoch, snapshot.capabilities.canSend else { throw TelegramConversationError.unavailable }
                    let file = try await provider.stageAttachment(id, epoch: epoch, data: result.data, name: result.file.name,
                        mime: result.file.mime, width: result.file.width ?? 0, height: result.file.height ?? 0)
                    staged.append(file)
                    if let image = result.thumbnail { draftThumbnails[file.id] = image }
                }
                guard snapshot.epoch == epoch, draft.attachments.count + staged.count <= 10,
                      (draft.attachments + staged).reduce(0, { $0 + $1.size }) <= 50 * 1024 * 1024 else { throw TelegramConversationError.files }
                change { $0.attachments += staged }
            } catch {
                for file in staged { await provider.discardAttachment(id, epoch: epoch, file: file.id) }
                for file in staged { draftThumbnails[file.id] = nil }
                problem = error.localizedDescription
            }
            importing = false
    }
    func removeFile(_ file: UUID) {
        change { $0.attachments.removeAll { $0.id == file } }
        draftThumbnails[file] = nil
        let epoch = snapshot.epoch
        Task { await provider?.discardAttachment(id, epoch: epoch, file: file) }
    }
    func download(_ message: TelegramMessage, cancel: Bool = false) {
        let epoch = snapshot.epoch
        Task { await provider?.downloadAttachment(id, epoch: epoch, message: message.messageID, cancel: cancel) }
    }
    func preview(_ message: TelegramMessage) {
        let epoch = snapshot.epoch
        Task {
            do {
                guard let provider, let file = message.attachment else { return }
                let url = try await provider.attachmentURL(id, epoch: epoch, message: message.messageID)
                _ = try await TelegramAttachmentIO.shared.validated(url, name: file.name)
                // Revalidate after disk/decode work, before displaying bytes.
                _ = try await provider.attachmentURL(id, epoch: epoch, message: message.messageID)
                guard snapshot.epoch == epoch else { return }
                previewMessage = message.messageID
                QuickLookPanel.show(url, owner: previewOwner)
            } catch { problem = "File unavailable. Download it again or open Telegram." }
        }
    }
    func save(_ message: TelegramMessage) {
        guard let file = message.attachment, !message.protectedContent else { return }
        let epoch = snapshot.epoch
        let panel = NSSavePanel(); panel.nameFieldStringValue = file.name
        panel.begin { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            Task {
                do {
                    guard let provider = self.provider else { return }
                    let source = try await provider.attachmentURL(self.id, epoch: epoch, message: message.messageID)
                    let bytes = try await TelegramAttachmentIO.shared.validated(source, name: file.name)
                    _ = try await provider.attachmentURL(self.id, epoch: epoch, message: message.messageID)
                    guard self.snapshot.epoch == epoch else { return }
                    try await TelegramAttachmentIO.shared.save(bytes, to: destination)
                } catch { self.problem = "The file could not be saved. Download it again or open Telegram." }
            }
        }
    }
}

actor TelegramAttachmentIO {
    static let shared = TelegramAttachmentIO()
    func validated(_ url: URL, name: String) throws -> Data {
        let bytes = try ChatAttachmentStorage.read(url, limit: ChatAttachmentLimits.telegram.fileBytes)
        _ = try ChatAttachmentStorage.descriptor(data: bytes, name: name, limits: .telegram)
        return bytes
    }
    func save(_ bytes: Data, to destination: URL) throws {
        let access = destination.startAccessingSecurityScopedResource()
        defer { if access { destination.stopAccessingSecurityScopedResource() } }
        try bytes.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
