import AgentPadTelegram
import SwiftUI

struct AddToFolderChooser: View {
    let request: SidebarFolderActions.Request
    @Bindable var model: SidebarFoldersModel
    var dismiss: () -> Void
    @State private var query = ""
    @State private var selection: UUID?
    @State private var newName: String?
    @State private var newFolderID: UUID?
    @State private var working = false
    @FocusState private var field: Field?
    @FocusState private var listFocused: Bool
    @AccessibilityFocusState private var accessibleSelection: UUID?
    private enum Field { case search, name }
    var folders: [SidebarCustomFolder] {
        model.snapshot.catalog.custom.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Add to folder…").font(Theme.display(13, weight: .semibold))
            TextField("Find a folder", text: $query).textFieldStyle(.roundedBorder).focused($field, equals: .search)
                .onSubmit { toggleSelected(close: true) }.accessibilityLabel("Find a folder")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(folders) { folder in
                            Button { selection = folder.id; toggle(folder, close: false) } label: {
                                HStack {
                                    Image(systemName: contains(folder) ? "checkmark" : folder.symbol).frame(width: 16)
                                    Text(folder.name).lineLimit(1).help(folder.name)
                                    Spacer()
                                }.padding(6).contentShape(Rectangle())
                                    .background(selection == folder.id ? Theme.chromeSelection : .clear, in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain).accessibilityLabel(folder.name)
                                .accessibilityValue(contains(folder) ? "Added" : "Not added")
                                .accessibilityAddTraits(selection == folder.id ? .isSelected : [])
                                .accessibilityFocused($accessibleSelection, equals: folder.id)
                                .id(folder.id)
                        }
                    }
                }.frame(height: min(230, CGFloat(folders.count) * 30))
                .onChange(of: selection) { _, id in
                    guard let id else { accessibleSelection = nil; return }
                    proxy.scrollTo(id)
                    Task { @MainActor in
                        await Task.yield()
                        if selection == id { accessibleSelection = id }
                    }
                }
            }
            if folders.isEmpty { Text(query.isEmpty ? "No custom folders yet" : "No matching folders").foregroundStyle(ChatAppearance.secondary) }
            Divider()
            if newName != nil {
                TextField("Folder name", text: Binding(get: { newName ?? "" }, set: { newName = $0 }))
                    .textFieldStyle(.roundedBorder).focused($field, equals: .name).onSubmit(create)
            } else {
                Button("New folder…") { newName = ""; field = .name }.buttonStyle(.plain)
            }
            SidebarFolderFailureView(model: model)
            Text("Your folders are local to this Mac.\nTelegram folders are edited in Telegram.")
                .font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
        }.font(Theme.display(12)).padding(14).frame(width: 280)
            .foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground)
            .disabled(working)
            .focusable().focused($listFocused).focusEffectDisabled()
            .onAppear { model.start(); selection = folders.first?.id; field = .search }
            .onChange(of: query) { _, _ in selection = folders.first?.id }
            .onChange(of: folders.map(\.id)) { _, ids in if selection == nil || !ids.contains(selection!) { selection = ids.first } }
            .onKeyPress(keys: [.upArrow, .downArrow, .space, .return, .escape]) { key in
                if key.key == .escape { dismiss(); return .handled }
                guard newName == nil, key.modifiers.intersection([.command,.option,.control,.shift]).isEmpty else { return .ignored }
                if key.key == .space { guard field == nil else { return .ignored }; toggleSelected(close: false); return .handled }
                if key.key == .return { toggleSelected(close: true); return .handled }
                field = nil; listFocused = true
                let index = folders.firstIndex { $0.id == selection } ?? 0
                if !folders.isEmpty { selection = folders[min(folders.count - 1, max(0, index + (key.key == .downArrow ? 1 : -1)))].id }
                return .handled
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Add to folder")
    }
    private func contains(_ folder: SidebarCustomFolder) -> Bool { model.snapshot.members[folder.id]?.contains(request.item) == true }
    private func toggleSelected(close: Bool) {
        if let folder = folders.first(where: { $0.id == selection }) { toggle(folder, close: close) }
    }
    private func toggle(_ folder: SidebarCustomFolder, close: Bool) {
        guard !working else { return }
        let present = !contains(folder); working = true
        Task {
            let success = await model.perform(.member(folder.id, request.item, present), binding: request.binding)
            working = false
            if success && close { dismiss() }
        }
    }
    private func create() {
        guard let name = newName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, !working else { return }
        working = true
        let id = newFolderID ?? UUID(); newFolderID = id
        Task {
            let success = await model.perform(.createAndAdd(id, name: name, symbol: "folder", item: request.item), binding: request.binding)
            working = false
            if success { dismiss() }
        }
    }
}

extension View {
    func addToFolderAnchor(_ item: SidebarItemReference?, windowID: UUID?, anchor: String? = nil, enabled: Bool = true,
                           actions: SidebarFolderActions = .shared) -> some View {
        modifier(AddToFolderAnchor(item: item, windowID: windowID, anchor: anchor, enabled: enabled, actions: actions))
    }
}
private struct AddToFolderAnchor: ViewModifier {
    var item: SidebarItemReference?
    var windowID: UUID?
    var anchor: String?
    var enabled: Bool
    @Bindable var actions: SidebarFolderActions
    private var matches: Bool {
        guard enabled, let item, let request = actions.request else { return false }
        return request.item == item && request.anchor == anchor && (request.windowID == nil || request.windowID == windowID)
    }
    func body(content: Content) -> some View {
        content.popover(isPresented: Binding(get: { matches }, set: { if !$0 && matches { actions.request = nil } }), arrowEdge: .trailing) {
            if let request = actions.request {
                AddToFolderChooser(request: request, model: actions.folders) { actions.request = nil }
            }
        }
    }
}
