import Foundation

/// A bounded, cancellable binary lane, separate from the JSON timeout and cache.
/// Attachments own a session; avatars reuse their scope's ephemeral session.
/// URLProtocol is injected by tests.
final class ChatAttachmentTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var continuation: CheckedContinuation<ChatAPI.Response, Error>?
    private var cancelled = false
    private var bytes = Data()
    private var response: HTTPURLResponse?
    private let limit: Int
    private let progress: @Sendable (Double) -> Void
    init(limit: Int, progress: @escaping @Sendable (Double) -> Void) { self.limit = limit; self.progress = progress }
    func run(_ request: URLRequest, upload: Data?, protocols: [AnyClass]?, session shared: URLSession? = nil) async throws -> ChatAPI.Response {
        // A shared session cannot set a resource timeout separately for each
        // task. Preserve the dedicated lane's total deadline as well as its
        // per-request inactivity timeout.
        let deadline: Task<Void, Never>? = shared == nil ? nil : Task { [weak self] in
            do { try await Task.sleep(for: .seconds(request.timeoutInterval)) } catch { return }
            self?.cancel()
        }
        defer { deadline?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session: URLSession
                if let shared { session = shared }
                else {
                    let config = URLSessionConfiguration.ephemeral
                    config.httpCookieAcceptPolicy = .never; config.httpShouldSetCookies = false
                    config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
                    config.timeoutIntervalForRequest = request.timeoutInterval
                    config.timeoutIntervalForResource = request.timeoutInterval
                    if let protocols { config.protocolClasses = protocols }
                    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                }
                lock.lock()
                self.continuation = continuation
                let task = upload.map { session.uploadTask(with: request, from: $0) } ?? session.dataTask(with: request)
                if shared != nil { task.delegate = self }
                self.task = task
                let cancel = cancelled
                lock.unlock()
                if cancel { task.cancel() }
                task.resume()
                if shared == nil { session.finishTasksAndInvalidate() }
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        // Error bodies get a small independent allowance; never allocate an
        // attacker-controlled Content-Length or decode an unbounded original.
        let bound = (self.response?.statusCode ?? 500) < 300 ? limit : 64 * 1024
        completionHandler(response.expectedContentLength > Int64(bound) ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let bound = (response?.statusCode ?? 500) < 300 ? limit : 64 * 1024
        guard bytes.count <= bound - data.count else { dataTask.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { progress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = continuation; self.continuation = nil; self.task = nil; let cancelled = cancelled; lock.unlock()
        if cancelled { continuation?.resume(throwing: CancellationError()) }
        else if let response, (300..<400).contains(response.statusCode) { continuation?.resume(throwing: ChatAPIError.redirect(response.statusCode)) }
        // A received refusal remains definitive even if its error body was
        // truncated by our bound (notably a proxy's explicit HTTP 413).
        else if error != nil, response.map({ (200..<300).contains($0.statusCode) }) ?? true {
            continuation?.resume(throwing: ChatAPIError.network("File transfer failed"))
        }
        else if let response {
            continuation?.resume(returning: .init(status: response.statusCode, body: bytes,
                retryAfter: ChatAPI.retryAfter(response.value(forHTTPHeaderField: "Retry-After")),
                headers: Dictionary(response.allHeaderFields.compactMap { key, value in
                    (key as? String).map { ($0.lowercased(), String(describing: value)) }
                }, uniquingKeysWith: { _, last in last })))
        } else { continuation?.resume(throwing: ChatAPIError.unexpectedAnswer("not HTTP")) }
    }
}

extension ChatAPI {
    func attachmentCommand(org: String, id: String, type: String, args: ChatJSON, token: String) async throws {
        let bytes = try ChatCommandEnvelope(commandId: id, org: org, type: type, args: args).encoded()
        try Self.check(try await postCommand(bytes, token: token))
    }
    func attachmentMetadata(org: String, id: String, token: String) async throws -> ChatAttachmentMetadata {
        try await call(ChatAttachmentMetadata.self, "GET", "/v1/orgs/\(org)/attachments/\(id)", token: token)
    }
    func attachmentUpload(org: String, id: String, data: Data, token: String, seconds: Int,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await attachmentBytes(path: "/v1/orgs/\(org)/attachments/\(id)/content", token: token,
            upload: data, limit: 64 * 1024, seconds: seconds, progress: progress)
    }
    func attachmentBytes(path: String, token: String, upload: Data? = nil, limit: Int, seconds: Int = 150,
                         progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Data {
        var request = URLRequest(url: server.baseURL.appendingPathComponent(path))
        request.httpMethod = upload == nil ? "GET" : "PUT"
        request.timeoutInterval = Double(seconds)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if let upload {
            request.setValue(String(upload.count), forHTTPHeaderField: "Content-Length")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let result = try await ChatAttachmentTransfer(limit: limit, progress: progress).run(request, upload: upload, protocols: attachmentProtocols)
        try Self.check(result)
        return result.body
    }
}
