import Foundation

/// Coalesces on the producer's queue, before flooding the main actor with Tasks.
/// Fixed windows (not a trailing debounce) also make progress during a burst.
final class CoalescedMainActorAction: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var generation: UInt64 = 0
    private let delay: TimeInterval
    private let action: @MainActor @Sendable () -> Void

    init(delay: TimeInterval = 0.05, action: @escaping @MainActor @Sendable () -> Void) {
        self.delay = delay
        self.action = action
    }

    func schedule() {
        let scheduled: UInt64? = lock.withLock {
            guard !pending else { return nil }
            pending = true
            return generation
        }
        guard let scheduled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.lock.withLock({
                guard self.pending, self.generation == scheduled else { return false }
                self.pending = false
                return true
            }) else { return }
            self.action()
        }
    }

    func cancel() {
        lock.withLock { pending = false; generation &+= 1 }
    }
}
