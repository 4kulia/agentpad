import Foundation

/// Lives with the owner, outside any view. A second Cmd-W cannot skip a failed
/// write. Submitted operations are deliberately not cancelled by this class.
@MainActor
final class TabCloseCoordinator {
    private struct Pending { let state: TabState; let close: () -> Void }
    private var pending: [TabID: Pending] = [:]
    let drafts: DraftRepository
    init(drafts: DraftRepository) { self.drafts = drafts }

    func save(_ state: TabState) throws {
        try state.persistEdits?()
        if let draft = state.draft {
            try drafts.save(draft)
            state.savedRevision = draft.revision
        }
        state.saveError = nil
    }
    @discardableResult
    func prepare(_ sessions: [Session], moving: Bool = false) -> Bool {
        var success = true
        for session in sessions {
            guard let state = session.tabState else { continue }
            state.leave(moving: moving)
            do { try save(state) }
            catch { state.saveError = error.localizedDescription; success = false }
        }
        return success
    }
    func request(_ session: Session, close: @escaping () -> Void) {
        guard let state = session.tabState else { close(); return }
        guard !hasPending(session.id) else { return }
        state.leave()
        do { try save(state); close() }
        catch {
            state.saveError = error.localizedDescription
            pending[session.id] = Pending(state: state, close: close)
        }
    }
    func hasPending(_ id: TabID) -> Bool {
        // A screen can retry its own save without going through this coordinator.
        if pending[id]?.state.saveError == nil { pending[id] = nil }
        return pending[id] != nil
    }
    func keepEditing(_ id: TabID) { pending[id]?.state.saveError = nil; pending[id] = nil }
    func retry(_ id: TabID) {
        guard let request = pending[id] else { return }
        do { try save(request.state); pending[id] = nil; request.close() }
        catch { request.state.saveError = error.localizedDescription }
    }
    func discard(_ id: TabID) {
        guard let request = pending[id], discardEdits(request.state) else { return }
        pending[id] = nil
        request.close()
    }
    @discardableResult
    func discardEdits(_ state: TabState) -> Bool {
        guard state.localForm?.working != true, state.publicationForm?.working != true else { return false }
        // Discard only the unsaved edit. A previously saved draft remains recoverable.
        state.draft = state.navigation.draftID.flatMap(drafts.draft)
        state.savedRevision = state.draft?.revision
        state.discardEdits?()
        state.saveError = nil
        return true
    }
}
