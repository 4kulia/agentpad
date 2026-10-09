import AppKit
import Foundation

extension ClaudeVersionApprovals.Pending {
    var attentionKey: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return AttentionEvent.identifier([executable.selectedPath, String(decoding: (try? encoder.encode(grant)) ?? Data(), as: UTF8.self)])
    }
}
extension ClaudeVersionApprovals {
    var attentionGroups: [[Pending]] {
        var keys: [String] = [], groups: [String: [Pending]] = [:]
        for item in pending {
            if groups[item.attentionKey] == nil { keys.append(item.attentionKey) }
            groups[item.attentionKey, default: []].append(item)
        }
        return keys.compactMap { groups[$0] }
    }
}

extension AttentionCoordinator {
    func focused(_ event: AttentionEvent) -> Bool {
        if case .terminal(let id) = event.destination { return terminalFocused(id) }
        if case .message(let channel, _, let thread, _) = event.destination {
            return ChatNotifications.isLooking(thread.map { "t:\($0)" } ?? "c:\(channel)")
        }
        if case .directMessage(let dm, _, let thread, _) = event.destination, let scope = event.scope, let key = ChatAttention.key(scope) {
            return ChatNotifications.isLooking(ChatDMRef(key, dm: dm).place + (thread.map { ":thread:\($0)" } ?? ""))
        }
        return AttentionFocus.focused(event.destination)
    }

    func valid(_ event: AttentionEvent) -> Bool {
        if event.scope != nil && !ChatAttention.valid(event, service: .shared) { return false }
        switch event.destination {
        case .terminal(let id): return terminalExists(id)
        case .external(let id): return ExternalSessionMonitor.shared.sessions.contains { $0.id == id && $0.monitorState == .attention }
        case .version(let id): return ClaudeVersionApprovals.shared.pending.contains { $0.id == id }
        case .sheet: return false // Legacy address; sheets no longer register decisions.
        case .tabAction(_, let id): return PendingConfirmations.shared.valid(id)
        case .invitation, .publicationProposal: return false
        default: return true
        }
    }

    /// Source projection lives independently of windows. Callbacks run after
    /// commits; the periodic pass covers expiry, recovery and tool-only resume.
    func refreshSources() {
        guard sourcesReady, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let ledger = AttentionLedger.shared, service = ChatService.shared, calls = TeamService.shared.calls
        let scope = service.connection?.orgKey.map { ChatAttention.scope($0, service) }
        let live = scope.map { observedScopes.contains($0) } ?? false
        var events = ChatAttention.events(service: service, calls: calls)
        if let key = service.connection?.orgKey, ChatAttention.personalAllowed(key, service) {
            if let scope, observedScopes.insert(scope).inserted {
                let restored = ledger.metadata.markers.values.compactMap(\.locator).filter {
                    $0.scope == scope && !$0.kind.needsDecision && valid($0)
                }
                ledger.upsert(restored, live: { $0.kind != .dm })
            }
            for agent in calls.agents {
                let status = service.publishStatus(agent, key: key).status
                if status == .unconfirmed || status == .unpublishUnconfirmed {
                    events.append(AttentionEvent(source: "agent-publication", object: agent.id.uuidString, kind: .decision,
                        destination: .recovery("publications"), scope: scope))
                }
            }
            for folder in calls.accessRequests where [.pending, .deciding].contains(folder.state) {
                guard folder.scope?.key == key,
                      let call = calls.executionIncoming(folder.callId), !call.state.isFinal, call.onThisDevice != false else { continue }
                if let channel = folder.scope?.channelId, !service.channelAgentAllowed(key, channel: channel) { continue }
                var event = AttentionEvent(source: "folder", object: folder.id, episode: folder.callId, kind: .folder,
                                           destination: .folder(folder.id, request: folder.callId), scope: scope)
                event.actionInFlight = folder.state == .deciding
                events.append(event)
            }
        }
        for group in ClaudeVersionApprovals.shared.attentionGroups {
            guard let item = group.first else { continue }
            events.append(AttentionEvent(source: "version", object: item.attentionKey, kind: .version, destination: .version(item.id)))
        }
        func block(_ id: String, _ present: Bool, destination: AttentionDestination = .recovery(nil)) {
            if present { events.append(AttentionEvent(source: "block", object: id, kind: .recovery, destination: destination)) }
        }
        block("journal", service.journalProblem != nil)
        block("recovery", service.recovery?.problem != nil || service.recovery?.blocked.isEmpty == false)
        block("processes", !TeamProcesses.shared.leftOvers().isEmpty)
        block("configuration", TeamService.shared.modeProblem != nil)
        block("calls", calls.storeProblem != nil, destination: .team(request: nil, outgoing: false))
        block("publications", !service.publishProblems.isEmpty, destination: .recovery("publications"))
        if case .needsSignIn = service.state {
            events.append(AttentionEvent(source: "connection", object: "sign-in", kind: .signIn, destination: .connect, scope: scope))
        } else {
            block("queue", !service.problems.isEmpty)
        }
        if case .notMember(let key, _) = service.state {
            events.append(AttentionEvent(source: "membership", object: key.orgId, kind: .account,
                                         destination: .organization(key.orgId), scope: scope))
        }
        // Only state-derived local waits need an episode registry. Requests,
        // messages, access requests and runs already have durable source IDs.
        var episodeKeys = Set<String>()
        events = events.map { event in
            guard ["version", "block", "connection"].contains(event.source) else { return event }
            episodeKeys.insert(event.id)
            let episode = AttentionEpisodes.shared.begin(event.id)
            return AttentionEvent(source: event.source, object: event.id, episode: episode, kind: event.kind,
                                  destination: event.destination, scope: event.scope)
        }
        AttentionEpisodes.shared.reconcile(keeping: episodeKeys)
        let ids = Set(events.map(\.id))
        for source in ["request", "publication-review", "folder", "version", "block", "connection", "agent-publication", "launch-help"] {
            ledger.reconcile(source: source, keeping: ids)
        }
        ledger.upsert(events, live: { $0.kind != .dm && ($0.scope == nil || live || $0.kind.needsDecision) })
        ledger.validateAll()
        AttentionSidebarModel.shared.refresh(service: service, ledger: ledger)
        navigation?.retryPending()
        refreshBadge()
    }

    func reconcileDelivered() async {
        guard sourcesReady, let manager = notificationManager else { return }
        let ledger = AttentionLedger.shared
        for id in await manager.identifiers() {
            if let event = ledger.event(id), valid(event) { continue }
            ledger.resolve(id)
            manager.remove(ids: [id])
        }
    }

    func endTerminalWaiting(_ id: UUID) {
        for event in AttentionLedger.shared.events where event.destination == .terminal(id) && event.kind == .input {
            AttentionLedger.shared.resolve(event.id)
        }
    }
}
