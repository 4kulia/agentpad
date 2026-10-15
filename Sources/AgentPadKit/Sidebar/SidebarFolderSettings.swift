import SwiftUI

struct SidebarFolderSettings: View {
    var compact = false
    @State private var folders = SidebarFoldersModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact { Text("Choose which folders appear in the sidebar. Your folders are local to this Mac.").font(Theme.display(12)) }
            Button("Folders…") { folders.sheetPresented = true }
        }.padding(compact ? 0 : 28)
            .task { folders.start() }
            .sheet(isPresented: $folders.sheetPresented) {
                FoldersSheet(model: folders, entries: entries) { folders.sheetPresented = false }
            }
    }
    private var entries: [SidebarFolderEntry] {
        if let store = TabRouter.shared.stores().first {
            let sidebar = ChatSidebarView(store: store, navigation: store.chatNavigation, model: ChatOrgCurrent.shared.model, folders: folders)
            return sidebar.folderEntries(sidebar.snapshot, includeHidden: true)
        }
        return folders.snapshot.catalog.order.flatMap { id -> [SidebarFolderEntry] in
            if id == "telegram" {
                return TelegramService.chats.connected ? TelegramService.chats.snapshot.lists.map(\.sidebarEntry) : [.init(id: id, title: "Telegram", kind: .connect)]
            }
            if let folder = folders.snapshot.catalog.custom.first(where: { SidebarEntryIdentity.custom($0.id) == id }) {
                return [.init(id: id, title: folder.name, kind: .custom(folder.id), symbol: folder.symbol,
                    count: folders.snapshot.members[folder.id]?.count ?? 0, visible: !folders.snapshot.catalog.hidden.contains(id))]
            }
            return [.init(id: id, title: id == "myAgents" ? "My agents" : "AgentPad", kind: .myAgents,
                visible: !folders.snapshot.catalog.hidden.contains(id), connected: id == "myAgents")]
        }
    }
}
