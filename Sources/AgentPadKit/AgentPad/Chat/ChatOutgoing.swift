import Foundation

/// The caller's side of a call through the server (docs/agentpad/DESIGN-D5.md):
/// `TeamCalls.ask` stores the call and its `request.create` together; the
/// outcome's notice is the one of 1.0.x, told once by the action runner.
@MainActor
enum ChatOutgoing {
    /// Calls are asked through the server only once the owner's side (D4,
    /// its `receive`) is in the same build: until then a request would wait
    /// with no Mac to take it, and `ask` keeps its refusal (`askNotYet`). Off
    /// in this build; tests and live checks turn it on (review D5-p2-1).
    static var asksOn = false

    static func install(calls: TeamCalls, service: ChatService = .shared) {
        calls.deliversAsks = asksOn
        calls.prepareCommand = { [weak service] key, type, args in
            guard let service else { throw TeamError.notConnected }
            do {
                return try service.prepareCommand(key, type: type, args: args)
            } catch ChatError.notConnected {
                throw TeamError.notConnected
            }
        }
        service.actionHandlers[.notifyOutcome] = NotifyOutcome(calls: calls)
        calls.cancelOnServer = { [weak service, weak calls] call in
            guard let service, let key = calls?.serverKey else { return TeamServerCore.cancelNotYet }
            return service.askToEnd(key, call.id, type: "request.cancel", states: nil)
        }
        calls.cancelChannelOnServer = { [weak service, weak calls] id in
            guard let service, let key = calls?.serverKey else { return TeamServerCore.cancelNotYet }
            return service.cancelChannelRequest(key, requestId: id.lowercased())
        }
        // Hints about the runs of the caller's calls (D4b §2.4): never state.
        service.onEphemeral = { [weak calls] org, type, body in
            guard let calls, calls.serverKey?.orgId == org, case .object(let o) = body, let id = o["request_id"]?.string else { return }
            switch type {
            case "run.activity": if let text = o["text"]?.string { calls.serverActivity(id, text) }
            case "run.access_wait": calls.serverActivity(id, "waiting for the owner to grant a folder")
            default: break
            }
        }
        // `409` (already being stopped, or final): its state comes as an event.
        service.commandOwners["request.cancel"] = { [weak service] key, _, _ in service?.runner(for: key).run() }
        // A call's `request.create` refused for good: the call ends (D5),
        // through the one dispatcher of the queue's answers.
        service.commandOwners["request.create"] = { [weak service] key, _, outcome in
            if case .refused = outcome { service?.settleCreates(key) }
        }
    }

    /// The notice's title of a call's end, by the server's own state (D10).
    static func outcomeTitle(_ call: TeamCalls.Outgoing) -> String {
        switch call.serverState {
        case "finished": return "\(call.address) answered"
        case "declined": return "\(call.colleague) declined your call"
        case "failed_to_start": return "\(call.address) could not start"
        case "stopped": return "Your call to \(call.address) was stopped"
        case "cancelled": return "Your call to \(call.address) was cancelled"
        case "expired": return "Your call to \(call.address) was not taken in time"
        case "failed" where call.version == 0: return "Your call to \(call.address) was not sent"
        case nil:
            // A call of this Mac's own store (1.0.x's words).
            switch call.report.state {
            case .done: return "\(call.address) answered"
            case .denied: return "\(call.colleague) declined your call"
            case .expired:
                return call.delivered ? "\(call.colleague) did not decide on your call in time" : "Your call to \(call.address) was not delivered"
            case .cancelled: return "Your call to \(call.address) was cancelled"
            default: return "Your call to \(call.address) failed"
            }
        default: return "Your call to \(call.address) failed"
        }
    }

    /// `notify_outcome` (6.12): the call's end or answer, told as 1.0.x tells
    /// it (`onOutgoingFinished`). Once: the action's row is `done` after it;
    /// a crash between the notice and that write may tell it again, which
    /// is harmless — a notice is not an action (DESIGN-D5).
    final class NotifyOutcome: ChatActionHandler {
        weak var calls: TeamCalls?
        init(calls: TeamCalls) { self.calls = calls }

        func perform(_ action: ChatAction, request: ChatRequest, key: ChatOrgKey) async -> ChatActionResult {
            await MainActor.run {
                // Another organization's calls are not in view: nothing to show for it now.
                guard let calls, calls.serverKey == key, let call = calls.outgoing(request.requestId) else { return .done }
                calls.onOutgoingFinished(call)
                return .done
            }
        }
    }
}
