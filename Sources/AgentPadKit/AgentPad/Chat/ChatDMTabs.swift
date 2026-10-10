import Foundation
import SwiftUI
import GRDB

@MainActor
enum ChatDMTabs {
    static func route(_ key: ChatOrgKey, peer: String, service: ChatService = .shared) -> ToolRoute? {
        guard service.dmAllowed(key) else { return nil }
        return service.dmList(key)?.people.first { $0.id == peer }?.route(key)
    }
    @discardableResult static func open(_ key: ChatOrgKey, peer: String, from store: WorkspaceStore? = nil,
                                       service: ChatService = .shared, navigation: SupportTabNavigation = SupportTabs.shared.navigation) -> Session? {
        guard let route = route(key, peer: peer, service: service) else { return nil }
        return navigation.open(route, from: store)
    }
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
    private(set) var result: ToolRoute?
    private var stopped = false
    private var members: [ChatOrgView.Member] = []
    @ObservationIgnored private var memberObservation: AnyDatabaseCancellable?
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
        memberObservation = ValueObservation.tracking { try ChatOrgView.Member.read($0) }.removeDuplicates()
            .start(in: store.queue, scheduling: .immediate, onError: { [weak self] _ in self?.members = [] }) { [weak self] members in
                guard let self, !stopped else { return }; self.members = members
            }
    }
    func choose(_ peer: String) {
        guard readable, people.contains(where: { $0.accountId == peer }) else { return }
        result = ChatDMTabs.route(key, peer: peer, service: service)
    }
    func stop() { stopped = true; memberObservation = nil; members = []; query = ""; result = nil }
}

struct ChatDMNewView: View {
    @Bindable var state: TabState
    let scope: OrgKey
    private var key: ChatOrgKey { .init(server: scope.server, accountId: scope.accountID, orgId: scope.orgID) }
    private var service = ChatService.shared
    var body: some View {
        Group {
            if let model = state.newDMModel, model.readable {
                ChatDMPeoplePicker(model: model) { route in
                    guard !state.isClosed, service.dmAllowed(key), let owner = SupportTabs.shared.owner(state) else { return }
                    model.stop(); state.newDMModel = nil
                    _ = SupportTabs.shared.navigation.router.rekey(owner.session.id, to: route)
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
    let open: (ToolRoute) -> Void
    @FocusState private var search: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New message").font(Theme.display(22, weight: .semibold))
            Text("Choose a person in your organization. Only the two of you can read the conversation.")
                .font(Theme.display(12)).foregroundStyle(ChatAppearance.secondary)
            TextField("Find a person by name or handle", text: $model.query).textFieldStyle(.roundedBorder).focused($search)
                .accessibilityLabel("Find a person")
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.people) { person in
                        Button { model.choose(person.accountId) } label: {
                            HStack(spacing: 12) {
                                ContactAvatar(stableID: person.accountId, name: person.name, kind: .person, size: 34, remote: .account(person.accountId, model.key))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(person.name).font(Theme.display(13, weight: .medium))
                                    Text("@\(person.handle)").font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(ChatAppearance.secondary)
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain).chatFocusRing()
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
