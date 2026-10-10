import GRDB

/// DatabaseQueue value observations fetch inside each writer transaction. A
/// connection-wide snapshot must instead let a burst of feed writes finish,
/// then read once off the main actor. Region callbacks do no SQL or UI work.
@MainActor
final class ChatSnapshotObservation<Value: Sendable> {
    private let queue: DatabaseQueue
    private let fetch: @Sendable (Database) throws -> Value
    private let onError: @MainActor (Error) -> Void
    private let onChange: @MainActor (Value) -> Void
    private var observation: AnyDatabaseCancellable?
    private var changes: CoalescedMainActorAction?
    private var reading: Task<Void, Never>?
    private var again = false
    private var active = true

    init(in queue: DatabaseQueue, tracking tables: [String], immediateInitialValue: Bool = false,
         fetch: @escaping @Sendable (Database) throws -> Value,
         onError: @escaping @MainActor (Error) -> Void,
         onChange: @escaping @MainActor (Value) -> Void) {
        self.queue = queue; self.fetch = fetch
        self.onError = onError; self.onChange = onChange
        let changes = CoalescedMainActorAction { [weak self] in self?.read() }
        self.changes = changes
        observation = DatabaseRegionObservation(tracking: tables.map { Table($0) })
            .start(in: queue, onError: { [weak self] error in
                Task { @MainActor [weak self] in self?.fail(error) }
            }, onChange: { _ in changes.schedule() })
        if immediateInitialValue {
            do { onChange(try queue.read(fetch)) }
            catch { fail(error) }
        } else {
            read()
        }
    }

    private func read() {
        guard active else { return }
        guard reading == nil else { again = true; return }
        let queue = queue, fetch = fetch
        reading = Task { [weak self] in
            // This read includes commits that already requested a refresh.
            self?.changes?.cancel()
            do {
                let value = try await queue.read(fetch)
                guard !Task.isCancelled, let self, self.active else { return }
                self.reading = nil
                self.onChange(value)
                if self.again { self.again = false; self.changes?.schedule() }
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        guard active else { return }
        cancel()
        onError(error)
    }

    func cancel() {
        active = false
        observation?.cancel(); observation = nil
        changes?.cancel(); changes = nil
        reading?.cancel(); reading = nil
    }

    deinit {
        observation?.cancel()
        changes?.cancel()
        reading?.cancel()
    }
}
