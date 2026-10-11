import Foundation

/// Blocking OS/file reads never occupy MainActor or Swift's cooperative pool.
/// A timeout abandons the result, not the thread: sysctl cannot be cancelled.
/// A bounded queue lets busy workers finish before starting more inspections.
enum BackgroundInspection {
    struct TimedOut: LocalizedError {
        var errorDescription: String? { "Process inspection timed out. Try again after the terminal responds." }
    }

    static let workerLimit = 4
    private static let workerQueue = DispatchQueue(label: "agentpad.process-inspection.workers",
                                                   qos: .userInitiated, attributes: .concurrent)
    private static let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "agentpad.process-inspection"
        queue.maxConcurrentOperationCount = workerLimit
        queue.underlyingQueue = workerQueue
        return queue
    }()
    // Deadlines must still fire when every inspection worker is blocked.
    private static let timers = DispatchQueue(label: "agentpad.process-inspection.timers", qos: .userInitiated)

    static func run<T: Sendable>(timeout: TimeInterval? = nil,
                                _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let reply = Reply<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                if let timeout {
                    timers.asyncAfter(deadline: .now() + timeout) {
                        reply.finish(.failure(TimedOut()))
                    }
                }
                workers.addOperation {
                    guard reply.isPending else { return }
                    reply.finish(Result { try operation() })
                }
            }
        } onCancel: {
            reply.finish(.failure(CancellationError()))
        }
    }

    private final class Reply<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var result: Result<T, Error>?
        var isPending: Bool { lock.withLock { result == nil } }

        func install(_ continuation: CheckedContinuation<T, Error>) {
            let result = lock.withLock {
                self.continuation = continuation
                return self.result
            }
            if let result { continuation.resume(with: result) }
        }

        func finish(_ result: Result<T, Error>) {
            let continuation = lock.withLock { () -> CheckedContinuation<T, Error>? in
                guard self.result == nil else { return nil }
                self.result = result
                return self.continuation
            }
            continuation?.resume(with: result)
        }
    }
}
