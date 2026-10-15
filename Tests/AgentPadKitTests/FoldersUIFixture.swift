import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

actor FoldersUIProvider: TelegramChatProvider {
    var snapshot: TelegramChatSnapshot
    var rows: [TelegramListKey:[TelegramChatRow]]
    var members: [UUID:Set<Int64>] = [:]
    var observers: [UUID:AsyncStream<TelegramChatSnapshot>.Continuation] = [:]
    var readResult = TelegramMarkReadResult()
    var readCalls = 0
    var opened = 0
    var holds: Set<TelegramListKey> = []
    var maximumWindows = 0
    var failTombstones = false
    var tombstoneAttempts = 0
    init(snapshot: TelegramChatSnapshot, rows: [TelegramListKey:[TelegramChatRow]]) { self.snapshot = snapshot; self.rows = rows }
    func chatSnapshots() -> AsyncStream<TelegramChatSnapshot> {
        let id = UUID(), pair = AsyncStream<TelegramChatSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = pair.continuation; pair.continuation.yield(snapshot); return pair.stream
    }
    func publish() {
        for index in snapshot.lists.indices {
            let list = snapshot.lists[index]
            snapshot.lists[index].windows = list.windows.mapValues { page(list.key, start: $0.offset, revision: list.revision) }
        }
        for observer in observers.values { observer.yield(snapshot) }
    }
    func page(_ list: TelegramListKey, start: Int, revision: UInt64) -> TelegramChatPage {
        let all = rows[list] ?? [], end = min(start + 50, all.count)
        let values = start < end ? all[start..<end].enumerated().compactMap { offset, row -> TelegramChatRow? in
            guard !row.hidden else { return nil }
            var result = row; result.listPosition = start + offset; return result
        } : []
        return .init(revision: revision, offset: start, rows: values, next: end < all.count ? start + 50 : nil)
    }
    func chatPage(list: TelegramListKey, from: Int, revision: UInt64, binding: TelegramProfileBinding) -> TelegramChatPage { page(list, start: from, revision: revision) }
    func setViewport(list: TelegramListKey, windows: Set<Int>, binding: TelegramProfileBinding) {
        guard let index = snapshot.lists.firstIndex(where: { $0.key == list }) else { return }
        guard Set(snapshot.lists[index].windows.keys) != windows else { return }
        snapshot.lists[index].windows = Dictionary(uniqueKeysWithValues: windows.map { ($0,page(list, start: $0, revision: snapshot.lists[index].revision)) })
        maximumWindows = max(maximumWindows, snapshot.lists.reduce(0) { $0 + $1.windows.count })
        publish()
    }
    func expandChats(list: TelegramListKey, showLess: Bool, binding: TelegramProfileBinding) {
        guard let index = snapshot.lists.firstIndex(where: { $0.key == list }) else { return }
        snapshot.lists[index].capacity = showLess ? 8 : min(snapshot.lists[index].counts.rows, snapshot.lists[index].capacity + 10)
        snapshot.lists[index].expanded = !showLess; publish()
    }
    func holdChatOrder(list: TelegramListKey, held: Bool, owner: UUID, binding: TelegramProfileBinding) {
        if held { holds.insert(list) } else { holds.remove(list) }
    }
    func setListVisible(_ list: TelegramListKey, visible: Bool, binding: TelegramProfileBinding) {
        guard let index = snapshot.lists.firstIndex(where: { $0.key == list }) else { return }
        snapshot.lists[index].visible = visible
        if !visible { snapshot.lists[index].windows = [:] }; publish()
    }
    func setListCollapsed(window: UUID, list: TelegramListKey, collapsed: Bool, binding: TelegramProfileBinding) {
        guard let index = snapshot.lists.firstIndex(where: { $0.key == list }) else { return }
        if collapsed { snapshot.lists[index].collapsedWindows.insert(window) } else { snapshot.lists[index].collapsedWindows.remove(window) }; publish()
    }
    func customMembers(binding: TelegramProfileBinding) -> [UUID:Set<Int64>] { members }
    func setCustomMember(folder: UUID, chat: Int64, member: Bool, binding: TelegramProfileBinding) {
        if member { members[folder,default: []].insert(chat) } else { members[folder]?.remove(chat) }; publish()
    }
    func setTombstoneFailure(_ value: Bool) { failTombstones = value }
    func applyTombstones(_ tombstones: Set<UUID>, binding: TelegramProfileBinding) throws {
        if !tombstones.isEmpty { tombstoneAttempts += 1 }
        if failTombstones { throw TelegramFolderError.unavailable }
        for id in tombstones { members[id] = nil }
    }
    func customSummaries(binding: TelegramProfileBinding) -> [TelegramFolderSummary] {
        Set(members.values.flatMap { $0 }).compactMap { id in
            guard let row = rows.values.flatMap({ $0 }).first(where: { $0.id.chat == id }) else { return nil }
            return .init(chat: id, title: row.title, date: row.lastMessageDate, unread: row.unreadCount > 0 || row.markedUnread,
                muted: row.muted, attention: row.attention != nil, hidden: row.hidden, available: row.kind.eligible)
        }
    }
    func setChatMode(_ id: TelegramChatID, mode: TelegramChatMode) { mutate(id.chat) { $0.hidden = mode == .hidden; $0.followEnabled = false } }
    func setFollow(_ chat: Int64, enabled: Bool, binding: TelegramProfileBinding) { mutate(chat) { $0.followEnabled = enabled } }
    func markAsRead(_ chat: Int64, retry: Set<TelegramMarkReadStep>?, binding: TelegramProfileBinding) -> TelegramMarkReadResult {
        readCalls += 1
        if readResult.succeeded { mutate(chat) { $0.unreadCount = 0; $0.attention = nil; $0.markedUnread = false } }
        return readResult
    }
    func setReadFailure() { readResult.failed = [.messages] }
    func mutate(_ chat: Int64, _ body: (inout TelegramChatRow) -> Void) {
        for key in rows.keys { for index in rows[key]!.indices where rows[key]![index].id.chat == chat { body(&rows[key]![index]) } }
        publish()
    }
    func setState(_ state: TelegramChatScanState, error: String? = nil) { snapshot.state = state; snapshot.error = error; publish() }
    func removeFolder(_ key: TelegramListKey) { snapshot.lists.removeAll { $0.key == key }; rows[key] = nil; publish() }
    func searchTelegram(_ query: String) -> AsyncStream<TelegramSearchSnapshot> {
        let matches = (rows[.main] ?? []).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.map { TelegramSearchHit(row: $0) }
        return AsyncStream { $0.yield(.init(query: query,hits: matches)); $0.finish() }
    }
    func resolveChat(_ hit: TelegramSearchHit) -> TelegramChatRow? { hit.row }
    func didOpenChat(_ id: TelegramChatID) { opened += 1 }
    func chat(_ id: TelegramChatID) -> TelegramChatRow? { rows.values.flatMap { $0 }.first { $0.id.chat == id.chat } }
    func setChatScanPaused(_ reason: String?) {}
}

@MainActor final class FoldersUIFixture {
    let root: URL
    let store: WorkspaceStore
    let org: ChatOrgModel
    let key = ChatOrgKey(server: try! ChatServerAddress(parsing: "https://folders.example"), accountId: "me", orgId: "aster")
    let telegram = TelegramChatsModel()
    let folderStore: SidebarFoldersStore
    let folders: SidebarFoldersModel
    let provider: FoldersUIProvider
    let ledger = AttentionLedger()
    let attention: AttentionSidebarModel
    let history: AgentSessionHistory
    let binding = TelegramProfileBinding(environment: .test, account: 42, connectionID: UUID())
    let launch = UUID(), clients = UUID(), pins = UUID()
    var people: [ChatDMPerson] = []
    var sidebar: ChatSidebarView {
        ChatSidebarView(store: store, navigation: store.chatNavigation, model: org, attention: attention,
            profileHistory: history, folders: folders, telegram: telegram,
            peopleSource: { [people] key in .init(entries: people.compactMap(\.conversation), me: key.accountId) })
    }
    init(catalog: SessionCatalog = .shared) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        struct SavedProfiles: Encodable { var version = 1; var profiles: [AgentProfile]; var bindings: [String:AgentProfileBinding] = [:] }
        let profilesURL = root.appendingPathComponent("agent-profiles.json")
        let profileRoot = root
        let saved = SavedProfiles(profiles: [("Copywriter",AgentTemplate.codex),("Data cleaner",AgentTemplate.claudeCode)].enumerated().map { index, item in
            let (name, template) = item
            return AgentProfile(id: UUID(uuidString: index == 0 ? "00000000-0000-4000-8000-000000000001" : "00000000-0000-4000-8000-000000000002")!,name: name,templateID: template.id,rosterID: template.id,folder: profileRoot,launchOptions: "",createdAt: Date().addingTimeInterval(-10800))
        })
        try JSONEncoder().encode(saved).write(to: profilesURL)
        let profiles = AgentProfileStore(fileURL: profilesURL)
        store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, agentProfiles: profiles, sessionCatalog: catalog,
            engineFactory: { TestEngine() }, optionsProvider: { _ in nil })
        history = AgentSessionHistory(profiles: profiles); history.scan = { [] }
        org = ChatOrgModel(me: "me") { _, _ in XCTFail("A folder action must not send an AgentPad command"); return "" }
        org.key = key
        org.set(.init(orgName: "Aster Studio", members: [
            .init(accountId: "me", handle: "aster", name: "Aster Studio", role: "member"),
            .init(accountId: "lea", handle: "lea", name: "Lea Brandt", role: "member")],
            teams: [.init(teamId: "aster", name: "Aster", isGeneral: true, archived: false, mine: true, members: ["me"])],
            channels: ["general","launch","support","old-release"].map { .init(channelId: $0, teamId: "aster", name: $0, createdBy: "me", archived: $0 == "old-release", version: 1) },
            channelActivity: ["launch": Date().addingTimeInterval(-720)], channelsServed: true, unread: ["launch": .init(count: 3)],
            channelAgents: [.init(channelId: "launch", agentId: "docs", name: "Docs reviewer", ownerAccountId: "lea", ownerHandle: "lea", description: "", access: "read", enabled: true, available: true)], agentsServed: true))
        folderStore = SidebarFoldersStore(url: root.appendingPathComponent("sidebar-folders.json")); folders = SidebarFoldersModel(store: folderStore)
        var snapshot = TelegramChatSnapshot(); snapshot.binding = binding
        snapshot.account = .init(environment: .test, account: 42, chat: 0); snapshot.state = .complete
        let base = Self.rows()
        let definitions: [(TelegramListKey,String,String,Int,Bool)] = [(.folder(1),"Work","Work",9,true),(.folder(2),"Family","Home",6,true),(.folder(3),"Unread","Unread",8,false),(.main,"All chats","All",151,true),(.archive,"Archive","Archive",37,false)]
        var lists: [TelegramListKey:[TelegramChatRow]] = [:]
        for (key,name,icon,count,visible) in definitions {
            let values = (0..<count).map { index -> TelegramChatRow in
                var row = base[index % base.count]
                if index >= base.count { row.id = .init(environment: .test, account: 42, chat: Int64(index + 100)); row.title = "Conversation \(index + 1)"; row.attention = nil; row.unreadCount = 0 }
                row.lists = [.folder(1),.main]; return row
            }
            lists[key] = values
            var counts = TelegramListCounts(); counts.rows = count; counts.unreadItems = key == .main ? 12 : 3; counts.unmutedUnreadItems = counts.unreadItems; counts.attentionItems = key == .folder(2) ? 0 : 2
            snapshot.lists.append(.init(key: key, name: name, icon: icon, visible: visible, complete: true, generation: 1, revision: 1,
                counts: counts, capacity: min(8,count), expanded: false, windows: [:], collapsedWindows: key == .folder(2) ? [store.windowID] : []))
        }
        snapshot.suggestionRows = Array(base.prefix(8)); snapshot.attentionRows = base.filter { $0.attention != nil }; snapshot.attentionTotal = 2
        snapshot.prepareAttention()
        provider = FoldersUIProvider(snapshot: snapshot, rows: lists)
        attention = AttentionSidebarModel(ledger: ledger, telegram: telegram, storesProvider: { [] })
        for (id,name,unread) in [("owen","Owen Hart",1),("lea","Lea Brandt",0),("sam","Sam Okafor",0)] {
            let peer = ChatDMCard.Peer(accountId: id, name: name, handle: id, active: true)
            let card = ChatDMCard(dmId: id, peer: peer, state: "active", version: 1, createdAt: "2026-10-14T10:00:00Z")
            people.append(.init(peer: peer, conversation: .init(card: card, lastUsed: Date().addingTimeInterval(-3600), roots: .init(count: unread), replies: 0, hasMessages: true)))
        }
    }
    func start() async throws {
        let defaults = [SidebarEntryIdentity.team(key, team: "aster"),SidebarEntryIdentity.people(key),"telegram","myAgents",SidebarEntryIdentity.teamAgents(key)]
        _ = await folderStore.perform(.load(defaults: defaults), binding: nil)
        _ = await folderStore.perform(.attach(provider,binding), binding: binding)
        for (id,name) in [(pins,"Pinned here"),(clients,"Clients"),(launch,"Launch")] { _ = await folderStore.perform(.create(id, name: name, symbol: "folder"), binding: binding) }
        for id in [clients,pins] { _ = await folderStore.perform(.visible(SidebarEntryIdentity.custom(id),false), binding: binding) }
        let members: [SidebarItemReference] = [.telegram(3),.agentpad(.channel(.init(server: key.server.description,account: key.accountId,org: key.orgId,channel: "launch"))),
            .agentpad(.person(.init(server: key.server.description,account: key.accountId,org: key.orgId,peer: "lea"))),
            .agentpad(.myAgent(store.agentProfiles.profiles[0].id)),.agentpad(.teamAgent(.init(server: key.server.description,account: key.accountId,org: key.orgId,agent: "docs")))]
        for member in members {
            _ = await folderStore.perform(.member(launch,member,true),binding: binding)
        }
        _ = await folderStore.perform(.refreshTelegram,binding: binding)
        for (index,id) in [SidebarEntryIdentity.team(key,team: "aster"),SidebarEntryIdentity.people(key),SidebarEntryIdentity.custom(launch),"telegram","myAgents",SidebarEntryIdentity.teamAgents(key)].enumerated() {
            _ = await folderStore.perform(.move(id,index),binding: binding)
        }
        telegram.attach(provider); folders.start()
        for _ in 0..<100 where !telegram.connected { try await Task.sleep(for: .milliseconds(5)) }
        store.chatSidebarPreferences.setEntryCollapsed(SidebarEntryIdentity.team(key,team: "aster"),true)
        store.chatSidebarPreferences.setEntryCollapsed(SidebarEntryIdentity.people(key),true)
        store.chatSidebarPreferences.setEntryCollapsed(SidebarEntryIdentity.teamAgents(key),true)
        var input = AttentionEvent(source: "fixture",object: "input",kind: .input,destination: .connect)
        input.localTitle = "deploy-bot"; input.localBody = "Needs input · Release"; ledger.upsert(input)
        attention.updateProjection()
        folders.observeSummaries(workspace: store, org: org, attention: attention,
            people: { [people] key in .init(entries: people.compactMap(\.conversation), me: key.accountId) })
        sidebar.configureFolderProjection()
    }
    func close() { store.terminate(); try? FileManager.default.removeItem(at: root) }
    static func rows() -> [TelegramChatRow] {
        ["Ellis Fen","Pine Studio","Harbor release","Nora Finch","Cedar mobile","Iris March","Maple house","Weekend sketchbook","Juniper rollout"].enumerated().map { index,title in
            var row = TelegramChatRow(id: .init(environment: .test,account: 42,chat: Int64(index + 1)),title: title,username: "",kind: [0,3,5].contains(index) ? .person : .supergroup,
                unreadCount: [1:7,2:5,3:2,4:14,6:31,7:4][index] ?? 0,unreadMentionCount: index == 1 ? 1 : 0,
                inMain: true,inArchive: false,pinned: index == 0,hidden: false,lastMessageDate: Int64(Date().timeIntervalSince1970) - [172800,120,240,360,3600,10800,21600,43200,86400][index],knownRelevant: true)
            row.muted = index == 4 || index == 6; row.lastOutgoing = index == 2
            row.lists = [.folder(1),.main]
            if index == 1 || index == 3 { row.attention = .init(destination: row.id,count: index == 1 ? 1 : 2,firstMessage: 10,lastDate: row.lastMessageDate,kind: index == 1 ? .mention : .direct,identity: "fixture:\(index)") }
            return row
        }
    }
}

@MainActor final class FoldersUIHost {
    let view: NSHostingView<AnyView>
    let window: NSWindow
    init(_ content: some View, width: CGFloat = 268, height: CGFloat = 930, dark: Bool = false, contrast: Bool = false) {
        _ = NSApplication.shared
        view = NSHostingView(rootView: AnyView(content.frame(width: width,height: height).background(Theme.chromeBackground)
            .foregroundStyle(Theme.chromeForeground).environment(\.colorScheme,dark ? .dark : .light)
            .environment(\.controlActiveState,.active)
            // The public contrast key is read-only; this SDK backing key is
            // confined to fixtures and does not change macOS accessibility settings.
            .environment(\._colorSchemeContrast,contrast ? .increased : .standard)))
        window = FoldersHostWindow(contentRect: NSRect(x: 0,y: 0,width: width,height: height),styleMask: [.borderless],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: contrast ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua) : (dark ? .darkAqua : .aqua))
        window.contentView = view; window.makeKeyAndOrderFront(nil)
    }
    func settle() async throws { try await Task.sleep(for: .milliseconds(200)); view.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
    func close() { window.contentView = nil; window.close() }
    func bitmap() throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds,to: bitmap)
        return bitmap
    }
    func png(_ url: URL) throws {
        try XCTUnwrap(bitmap().representation(using: .png,properties: [:])).write(to: url)
    }
    func descendants(_ root: NSView? = nil) -> [NSView] {
        let root = root ?? view
        return [root] + root.subviews.flatMap { descendants($0) }
    }
    func scrolls(_ root: NSView? = nil) -> [NSScrollView] {
        let root = root ?? view
        return (root as? NSScrollView).map { [$0] } ?? root.subviews.flatMap { scrolls($0) }
    }
    private func walk(_ value: Any, depth: Int = 0) -> [FoldersAXNode] {
        guard depth < 40, let object = value as? NSObject else { return [] }
        let element = FoldersAXNode(object: object)
        return [element] + element.children.flatMap { walk($0,depth: depth + 1) }
    }
    var elements: [FoldersAXNode] {
        (window.attachedSheet?.contentView.map { walk($0) } ?? []) + walk(view)
    }
    var popupElements: [FoldersAXNode] {
        NSApp.windows.filter { $0 !== window && $0.isVisible }.compactMap(\.contentView).flatMap { walk($0) }
    }
    func labels() -> [String] { elements.compactMap { $0.accessibilityLabel() ?? $0.accessibilityTitle() ?? $0.accessibilityValue() as? String } }
    @discardableResult func press(_ label: String, popup: Bool = false) -> Bool {
        (popup ? popupElements : elements).first { $0.accessibilityLabel() == label || $0.accessibilityTitle() == label }?.accessibilityPerformPress() ?? false
    }
    func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = [], throughApp: Bool = false) {
        guard let event = NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: (123...126).contains(code) ? modifiers.union([.function,.numericPad]) : modifiers,timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,context: nil,characters: characters,charactersIgnoringModifiers: characters,isARepeat: false,keyCode: code) else { return }
        if throughApp { NSApp.sendEvent(event) } else { window.sendEvent(event) }
    }
}

private final class FoldersHostWindow: NSWindow { override var canBecomeKey: Bool { true }; override var isKeyWindow: Bool { true } }

/// SwiftUI virtual AX nodes expose ObjC selectors without protocol conformance.
@MainActor struct FoldersAXNode {
    let object: NSObject
    func attribute(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
    var children: [NSObject] { attribute("accessibilityChildren") as? [NSObject] ?? [] }
    func accessibilityLabel() -> String? { attribute("accessibilityLabel") as? String }
    func accessibilityTitle() -> String? { attribute("accessibilityTitle") as? String }
    func accessibilityValue() -> Any? { attribute("accessibilityValue") }
    func accessibilityFrame() -> CGRect {
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")) else { return .zero }
        return (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
    }
    func focus() { object.setValue(true,forKey: "accessibilityFocused") }
    func accessibilityPerformPress() -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (NSObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector),to: Press.self)(object,selector)
    }
}
