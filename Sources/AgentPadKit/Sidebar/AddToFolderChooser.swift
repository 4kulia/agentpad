import AgentPadTelegram
import SwiftUI

struct AddToFolderChooser: View {
    let request: SidebarFolderActions.Request
    @Bindable var model: SidebarFoldersModel
    @Bindable var draft: SidebarFolderActions.Draft = .init()
    var cancel: (() -> Void)?
    var dismiss: () -> Void
    @FocusState private var field: Field?
    @FocusState private var listFocused: Bool
    @AccessibilityFocusState private var accessibleSelection: UUID?
    private enum Field { case search, name }
    var folders: [SidebarCustomFolder] {
        model.snapshot.catalog.custom.filter { draft.query.isEmpty || $0.name.localizedCaseInsensitiveContains(draft.query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: 14) {
            Text("Add to folder…").font(Theme.display(18, weight: .semibold))
            Text("Find a folder").font(Theme.display(11)).foregroundStyle(.secondary)
            TextField("Find a folder", text: $draft.query).textFieldStyle(.roundedBorder).focused($field, equals: .search)
                .onSubmit { toggleSelected(close: true) }.accessibilityLabel("Find a folder")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(folders) { folder in
                            Button { draft.selection = folder.id; toggle(folder, close: false) } label: {
                                HStack {
                                    Image(systemName: contains(folder) ? "checkmark.square.fill" : "square").frame(width: 16)
                                    Text(folder.name).lineLimit(1).help(folder.name)
                                    Spacer()
                                }.padding(6).contentShape(Rectangle())
                                    .background(draft.selection == folder.id ? Theme.chromeSelection : .clear, in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain).accessibilityLabel(folder.name)
                                .accessibilityValue(contains(folder) ? "Added" : "Not added")
                                .accessibilityAddTraits(draft.selection == folder.id ? .isSelected : [])
                                .accessibilityFocused($accessibleSelection, equals: folder.id)
                                .id(folder.id)
                        }
                    }
                }.frame(height: min(230, CGFloat(folders.count) * 30))
                .onChange(of: draft.selection) { _, id in
                    guard let id else { accessibleSelection = nil; return }
                    proxy.scrollTo(id)
                    Task { @MainActor in
                        await Task.yield()
                        if draft.selection == id { accessibleSelection = id }
                    }
                }
            }
            if folders.isEmpty { Text(draft.query.isEmpty ? "No custom folders yet" : "No matching folders").foregroundStyle(ChatAppearance.secondary) }
            if draft.newName != nil {
                Text("Folder name").font(Theme.display(11)).foregroundStyle(.secondary)
                TextField("Folder name", text: Binding(get: { draft.newName ?? "" }, set: { draft.newName = $0 }))
                    .textFieldStyle(.roundedBorder).focused($field, equals: .name).onSubmit(create)
            } else {
                Button("New folder…") { draft.newName = ""; field = .name }
            }
            SidebarFolderFailureView(model: model)
            Text("Your folders are local to this Mac. Telegram folders are edited in Telegram.")
                .font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Theme.chromeSelection, in: RoundedRectangle(cornerRadius: 7))
          }.padding(24)
          Divider()
          HStack {
              Spacer()
              Button("Cancel") { (cancel ?? dismiss)() }.accessibilityIdentifier("add-folder-cancel")
              Button("Add") { if draft.newName != nil { create() } else { dismiss() } }
                  .buttonStyle(PopupPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                  .disabled(draft.newName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
                  .accessibilityIdentifier("add-folder-apply")
          }.padding(.horizontal, 24).padding(.vertical, 14)
        }.font(Theme.display(12))
            .foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground)
            .disabled(draft.working)
            .focusable().focused($listFocused).focusEffectDisabled()
            .onAppear { model.start(); if draft.selection == nil { draft.selection = folders.first?.id }; field = .search }
            .onChange(of: draft.query) { _, _ in draft.selection = folders.first?.id }
            .onChange(of: folders.map(\.id)) { _, ids in if draft.selection == nil || !ids.contains(draft.selection!) { draft.selection = ids.first } }
            .onKeyPress(keys: [.upArrow, .downArrow, .space, .return, .escape]) { key in
                if key.key == .escape { dismiss(); return .handled }
                guard draft.newName == nil, key.modifiers.intersection([.command,.option,.control,.shift]).isEmpty else { return .ignored }
                if key.key == .space { guard field == nil else { return .ignored }; toggleSelected(close: false); return .handled }
                if key.key == .return { toggleSelected(close: true); return .handled }
                field = nil; listFocused = true
                let index = folders.firstIndex { $0.id == draft.selection } ?? 0
                if !folders.isEmpty { draft.selection = folders[min(folders.count - 1, max(0, index + (key.key == .downArrow ? 1 : -1)))].id }
                return .handled
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Add to folder")
    }
    private func contains(_ folder: SidebarCustomFolder) -> Bool { model.snapshot.members[folder.id]?.contains(request.item) == true }
    private func toggleSelected(close: Bool) {
        if let folder = folders.first(where: { $0.id == draft.selection }) { toggle(folder, close: close) }
    }
    private func toggle(_ folder: SidebarCustomFolder, close: Bool) {
        guard !draft.working else { return }
        let present = !contains(folder); draft.working = true
        Task {
            let success = await model.perform(.member(folder.id, request.item, present), binding: request.binding)
            draft.working = false
            if success && close { dismiss() }
        }
    }
    private func create() {
        guard let name = draft.newName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, !draft.working else { return }
        draft.working = true
        let id = draft.newFolderID ?? UUID(); draft.newFolderID = id
        Task {
            let success = await model.perform(.createAndAdd(id, name: name, symbol: "folder", item: request.item), binding: request.binding)
            draft.working = false
            if success { dismiss() }
        }
    }
}

extension View {
    func addToFolderAnchor(_ item: SidebarItemReference?, windowID: UUID?, anchor: String? = nil, enabled: Bool = true,
                           actions: SidebarFolderActions = .shared) -> some View {
        // Presentation belongs to the initiating window, independent of row
        // visibility, virtualized anchors and context-menu lifetimes.
        self
    }
}
