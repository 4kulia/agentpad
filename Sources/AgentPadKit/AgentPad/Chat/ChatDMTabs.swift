import Foundation
import SwiftUI
import GRDB

@MainActor
enum ChatDMTabs {
    static func title(_ ref: ChatDMRef, service: ChatService = .shared) -> String {
        guard let key = ref.key, service.dmAllowed(key, ref.dm) else { return "Direct message" }
        return service.orgSessions[key]?.dmList?.entries.first { $0.id == ref.dm }?.card.peer.name ?? "Direct message"
    }
    @discardableResult static func open(_ ref: ChatDMRef, from store: WorkspaceStore? = nil, service: ChatService = .shared,
                                       navigation: SupportTabNavigation = SupportTabs.shared.navigation) -> Session? {
        guard let key = ref.key, service.dmAllowed(key, ref.dm) else { return nil }
        used(ref, service: service)
        _ = service.dmList(key)
        return navigation.open(.directMessage(ref), from: store)
    }
    static func used(_ ref: ChatDMRef, service: ChatService) {
        guard let key = ref.key, service.dmAllowed(key, ref.dm) else { return }
        try? service.orgSessions[key]?.store?.dmWrite { db in
            try db.execute(sql: "INSERT INTO dm_preferences (dm_id, opened) VALUES (?, ?) ON CONFLICT(dm_id) DO UPDATE SET opened = excluded.opened", arguments: [ref.dm, ChatService.now()])
        }
    }
}

@MainActor @Observable
final class ChatDMNewModel {
    let key: ChatOrgKey
    let service: ChatService
    weak var state: TabState?
    var query = ""
    private(set) var pending: String?
    private(set) var problem: String?
    private(set) var result: String?
    private var stopped = false
    private var chosen: String?
    private var members: [ChatOrgView.Member] = []
    @ObservationIgnored private var memberObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    var readable: Bool { !stopped && state?.isClosed != true && service.dmAllowed(key) }
    var people: [ChatOrgView.Member] {
        guard readable else { return [] }
        return Self.filter(members, me: key.accountId, query: query)
    }
    static func filter(_ members: [ChatOrgView.Member], me: String, query: String) -> [ChatOrgView.Member] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return members.filter { $0.accountId != me && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.handle.localizedCaseInsensitiveContains(query)) }
    }
    init(key: ChatOrgKey, state: TabState?, service: ChatService = .shared) {
        self.key = key; self.state = state; self.service = service
        guard let store = service.orgSessions[key]?.store else { return }
        memberObservation = ValueObservation.tracking { try ChatOrgView.read($0).members }.removeDuplicates()
            .start(in: store.queue, scheduling: .immediate, onError: { [weak self] _ in self?.members = [] }) { [weak self] members in
                guard let self, !stopped else { return }; self.members = members
            }
    }
    func choose(_ peer: String) {
        guard readable, pending == nil, people.contains(where: { $0.accountId == peer }) else { return }
        if let known = service.dmList(key)?.entries.first(where: { $0.card.peer.accountId == peer }) { result = known.id; return }
        do {
            chosen = peer; problem = nil
            pending = try service.beginDM(key, peer: peer)
            guard let store = service.orgSessions[key]?.store, let command = pending else { return }
            observation = ValueObservation.tracking { db in
                let id = try String.fetchOne(db, sql: "SELECT dm_id FROM dm_open_results WHERE command_id = ?", arguments: [command])
                let card = try id.flatMap { try ChatDMStore.card(db, $0) }
                let failure = try String.fetchOne(db, sql: "SELECT COALESCE(error, state) FROM outbox WHERE command_id = ? AND state IN ('failed', 'dropped', 'unconfirmed')", arguments: [command])
                return (id, card, failure)
            }.start(in: store.queue, scheduling: .immediate, onError: { [weak self] _ in self?.problem = "The conversation could not be opened." }) { [weak self] id, card, failure in
                guard let self, readable, chosen == peer else { return }
                if let id, card?.peer.accountId == peer, service.dmAllowed(key, id) { result = id; pending = nil; observation = nil }
                else if failure != nil { problem = "The conversation could not be opened. Check the connection and try again."; pending = nil; observation = nil }
            }
        } catch { problem = "The conversation could not be opened. Check the connection and try again."; pending = nil }
    }
    func stop() { stopped = true; memberObservation = nil; members = []; observation = nil; query = ""; chosen = nil; result = nil; pending = nil }
}

struct ChatDMNewView: View {
    @Bindable var state: TabState
    let scope: OrgKey
    private var key: ChatOrgKey { .init(server: scope.server, accountId: scope.accountID, orgId: scope.orgID) }
    private var service = ChatService.shared
    var body: some View {
        Group {
            if let model = state.newDMModel, model.readable {
                ChatDMPeoplePicker(model: model) { dm in
                    guard !state.isClosed, service.dmAllowed(key, dm), let owner = SupportTabs.shared.owner(state) else { return }
                    let ref = ChatDMRef(key, dm: dm)
                    ChatDMTabs.used(ref, service: service)
                    _ = service.dmList(key)
                    model.stop(); state.newDMModel = nil
                    _ = SupportTabs.shared.navigation.router.rekey(owner.session.id, to: .directMessage(ref))
                }
            } else { Text(service.connection?.orgKey == key ? "Checking access…" : "Not connected").foregroundStyle(ChatAppearance.secondary) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(ChatAppearance.surface)
            .onChange(of: service.dmAllowed(key), initial: true) { _, allowed in
                if allowed, state.newDMModel == nil { state.newDMModel = ChatDMNewModel(key: key, state: state) }
                else if !allowed { state.newDMModel?.stop(); state.newDMModel = nil }
            }
    }
}

struct ChatDMPeoplePicker: View {
    @Bindable var model: ChatDMNewModel
    let open: (String) -> Void
    @FocusState private var search: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New message").font(Theme.display(22, weight: .semibold))
            Text("Choose a person in your organization. Only the two of you can read the conversation.")
                .font(Theme.display(12)).foregroundStyle(ChatAppearance.secondary)
            TextField("Find a person by name or handle", text: $model.query).textFieldStyle(.roundedBorder).focused($search)
                .accessibilityLabel("Find a person")
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(ChatAppearance.failure) }
            if model.pending != nil { ProgressView("Opening conversation…").controlSize(.small) }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.people) { person in
                        Button { model.choose(person.accountId) } label: {
                            HStack(spacing: 12) {
                                ContactAvatar(stableID: person.accountId, name: person.name, kind: .person, size: 34)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(person.name).font(Theme.display(13, weight: .medium))
                                    Text("@\(person.handle)").font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(ChatAppearance.secondary)
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain).chatFocusRing().disabled(model.pending != nil)
                    }
                    if model.people.isEmpty { Text("No people found").foregroundStyle(ChatAppearance.secondary).padding(24) }
                }
            }
        }.padding(28).frame(maxWidth: 600).foregroundStyle(Theme.chromeForeground)
            .onAppear { search = true }
            .onChange(of: model.result) { _, result in if let result { open(result) } }
    }
}


extension ChatService {
    func dmTab(_ ref: ChatDMRef, owner: UUID, open: Bool) {
        if open { openDMTabs[ref, default: []].insert(owner) }
        else { openDMTabs[ref]?.remove(owner); if openDMTabs[ref]?.isEmpty == true { openDMTabs[ref] = nil } }
        for (key, session) in orgSessions { session.sync?.dm.setOpen(Set(openDMTabs.keys.filter { $0.belongs(to: key) }.map(\.dm))) }
    }
}
