import AgentPadTelegram
import SwiftUI

struct FoldersSheet: View {
    @Bindable var model: SidebarFoldersModel
    var entries: [SidebarFolderEntry]
    var telegram: TelegramChatsModel = TelegramService.chats
    var dismiss: () -> Void
    @Environment(\.popupCoordinator) private var coordinator
    @FocusState private var nameFocused: Bool
    @FocusState private var listFocused: Bool
    @Environment(\.colorScheme) private var scheme
    private var rows: [SidebarFolderEntry] {
        let catalog = model.snapshot.catalog
        return catalog.order.flatMap { id -> [SidebarFolderEntry] in
            if id == "telegram" {
                let group = SidebarFolderEntry(id: id, title: "Telegram", kind: .connect, symbol: "paperplane", connected: telegram.connected)
                return [group] + (telegram.connected ? telegram.snapshot.lists.map(\.sidebarEntry) : [])
            }
            if let folder = catalog.custom.first(where: { SidebarEntryIdentity.custom($0.id) == id }) {
                return [.init(id: id, title: folder.name, kind: .custom(folder.id), symbol: folder.symbol,
                    count: model.snapshot.members[folder.id]?.count ?? folder.items.count, visible: !catalog.hidden.contains(id))]
            }
            guard var entry = entries.first(where: { $0.id == id }) else { return [] }
            entry.visible = !catalog.hidden.contains(id); return [entry]
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Folders").font(Theme.display(18, weight: .semibold))
                Text("Choose what the sidebar shows and in which order. Needs attention always stays on top.")
                    .font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary)
            }.padding(24)
            ScrollViewReader { proxy in
                PopupScrollBody(maxHeight: 440) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        Text("SIDEBAR ORDER").font(Theme.display(9)).tracking(1).foregroundStyle(ChatAppearance.secondary).padding(6)
                        ForEach(rows) { entry in
                            sheetRow(entry).id(entry.id)
                            Divider()
                        }
                    }.padding(.horizontal, 20)
                }
                .onChange(of: model.popupSelection) { _, id in if let id { proxy.scrollTo(id) } }
            }
            SidebarFolderFailureView(model: model).padding(.horizontal, 12)
            Text("Telegram folders keep Telegram's order. Nothing here leaves this Mac.")
                .font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            Divider()
            HStack(spacing: 10) {
                Button("New folder", systemImage: "plus") { model.newFolder() }
                Spacer(minLength: 0)
                if model.editing != nil {
                    Button("Cancel") {
                        model.editing = nil; model.editingName = ""
                        if let page = model.popup { coordinator?.dismiss(page, reason: .cancel) }
                    }
                }
                Button("Done") {
                    if let id = model.editing { rename(id, close: true) } else { dismiss() }
                }.buttonStyle(PopupPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("folders-done")
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }.background(Theme.chromeBackground).foregroundStyle(Theme.chromeForeground)
            .focusable().focused($listFocused).focusEffectDisabled()
            .onAppear {
                model.start()
                if !rows.contains(where: { $0.id == model.popupSelection }) { model.popupSelection = rows.first?.id }
                listFocused = true
                if let id = model.editing {
                    model.popupSelection = SidebarEntryIdentity.custom(id); nameFocused = true
                }
                presentDelete()
            }
            .onChange(of: rows.map(\.id)) { old, ids in
                guard let selection = model.popupSelection, !ids.contains(selection) else { return }
                let index = old.firstIndex(of: selection) ?? 0
                model.popupSelection = ids.isEmpty ? nil : ids[min(index, ids.count - 1)]
                nameFocused = false; listFocused = true
            }
            .onChange(of: model.editing) { _, id in
                if let folder = model.snapshot.catalog.custom.first(where: { $0.id == id }) {
                    model.editingName = folder.name; model.popupSelection = SidebarEntryIdentity.custom(folder.id); nameFocused = true
                } else { listFocused = true }
            }
            .onKeyPress(keys: [.upArrow,.downArrow,.space,.return,.delete,.escape]) { press in key(press) }
            .onChange(of: model.deleting?.id) { _, _ in presentDelete() }
            .accessibilityElement(children: .contain).accessibilityLabel("Folders")
    }
    private func sheetRow(_ entry: SidebarFolderEntry) -> some View {
        let child: Bool = { if case .telegram = entry.kind { true } else { false } }()
        let custom: Bool = { if case .custom = entry.kind { true } else { false } }()
        let iconColor = custom ? SidebarFolderTag.customColor(scheme) : entry.moveID == "telegram" ? ChatAppearance.accent : ChatAppearance.secondary
        return HStack(spacing: 9) {
            if !child {
                Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(ChatAppearance.secondary).frame(width: 12)
                    .onDrag { SidebarDragRegistry.provider(.init(entry: entry.moveID, binding: model.snapshot.binding)) }
                    .accessibilityLabel("Move \(entry.title)")
                    .accessibilityAction(named: "Move up") { model.move(entry, by: -1) }
                    .accessibilityAction(named: "Move down") { model.move(entry, by: 1) }
            }
            Image(systemName: entry.symbol).frame(width: 22, height: 22).font(.system(size: 12))
                .foregroundStyle(iconColor)
                .background(custom || child ? iconColor.opacity(0.11) : Theme.chromeSelection, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                if case .custom(let id) = entry.kind, model.editing == id {
                    TextField("Folder name", text: $model.editingName).textFieldStyle(.roundedBorder).focused($nameFocused)
                        .onSubmit { rename(id) }
                } else { Text(entry.title).lineLimit(1).help(entry.title) }
                Text(caption(entry)).font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if case .custom(let id) = entry.kind {
                Button("Rename") { beginRename(id) }.buttonStyle(.plain)
                Button("Delete", role: .destructive) { model.deleting = model.snapshot.catalog.custom.first { $0.id == id } }
                    .buttonStyle(PopupDestructiveButtonStyle())
            }
            if entry.kind == .connect {
                if !telegram.connected { Button("Connect") { dismiss(); SupportTabs.shared.settings(.telegram) } }
            } else {
                Toggle("Show \(entry.title)", isOn: Binding(get: { entry.visible }, set: { model.setVisible(entry, $0) }))
                    .toggleStyle(.checkbox).labelsHidden().controlSize(.small).disabled(!entry.connected)
            }
            if !child {
                Button { model.move(entry, by: -1) } label: { Image(systemName: "arrow.up") }
                    .accessibilityLabel("Move \(entry.title) up")
            }
        }.font(Theme.display(11)).padding(.vertical, 9).padding(.horizontal, 6).padding(.leading, child ? 24 : 0).frame(minHeight: 44)
            .background(model.popupSelection == entry.id ? Theme.chromeSelection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle()).onTapGesture { model.popupSelection = entry.id; listFocused = true }
            .accessibilityElement(children: .contain).accessibilityLabel("\(entry.title), \(entry.kindLabel)")
            .accessibilityValue(model.popupSelection == entry.id ? "Selected" : "")
            .opacity(entry.connected ? 1 : 0.55)
            .onDrop(of: [SidebarDragRegistry.entryType], isTargeted: nil) { providers in
                SidebarDragRegistry.receive(providers, entry: true) { value in
                    guard let id = value.entry, let destination = model.snapshot.catalog.order.firstIndex(of: entry.moveID) else { return }
                    model.run(.move(id, destination))
                }
            }
    }
    private func caption(_ entry: SidebarFolderEntry) -> String {
        if entry.kind == .connect {
            return telegram.connected ? "One block · order follows Telegram · edit folders in Telegram" + (telegram.folderStatus.map { " · " + $0 } ?? "") : "Connect to show its folders"
        }
        if !entry.connected { return "Not connected" }
        let unit: String = switch entry.kind { case .telegram: "chats"; case .team: "channels"; case .people: "direct messages"; case .myAgents, .teamAgents: "agents"; default: "items" }
        return "\(entry.kindLabel) · \(entry.count) \(unit)\(entry.provisional ? " so far" : "")"
    }
    private func beginRename(_ id: UUID) {
        model.editing = id
        model.editingName = model.snapshot.catalog.custom.first { $0.id == id }?.name ?? ""
        nameFocused = true
    }
    private func rename(_ id: UUID, close: Bool = false) {
        guard let folder = model.snapshot.catalog.custom.first(where: { $0.id == id }) else { return }
        let value = model.editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let binding = model.snapshot.binding
        Task {
            if await model.perform(.rename(id, name: value, symbol: folder.symbol), binding: binding) {
                model.editing = nil; model.editingName = ""
                if close { dismiss() }
            }
        }
    }
    private func presentDelete() {
        guard let folder = model.deleting, let coordinator, !coordinator.locksDismissal else { return }
        model.deleting = nil
        coordinator.presentConfirmation(title: "Delete custom folder", message: "Delete “\(folder.name)”?\n\nItems stay where they are.", verb: "Delete") {
            model.run(.delete(folder.id))
        }
    }
    private func key(_ press: KeyPress) -> KeyPress.Result {
        let modifiers = press.modifiers.intersection([.command,.option,.control,.shift])
        if press.key == .escape { if model.editing != nil { model.editing = nil } else { dismiss() }; return .handled }
        guard !nameFocused, let entry = rows.first(where: { $0.id == model.popupSelection }) else { return .ignored }
        if press.key == .upArrow || press.key == .downArrow {
            let delta = press.key == .downArrow ? 1 : -1
            if modifiers == [.option,.command] { model.move(entry, by: delta) }
            else if modifiers.isEmpty, let index = rows.firstIndex(where: { $0.id == model.popupSelection }) {
                model.popupSelection = rows[min(rows.count - 1, max(0, index + delta))].id
            } else { return .ignored }
            return .handled
        }
        if press.key == .space, entry.kind != .connect, entry.connected { model.setVisible(entry, !entry.visible); return .handled }
        if case .custom(let id) = entry.kind {
            if press.key == .return { beginRename(id); return .handled }
            if press.key == .delete, modifiers == .command { model.deleting = model.snapshot.catalog.custom.first { $0.id == id }; return .handled }
        }
        return .ignored
    }
}

extension SidebarFoldersModel {
    func presentPopup(in coordinator: PopupCoordinator, entries: @escaping () -> [SidebarFolderEntry],
                      telegram: TelegramChatsModel = TelegramService.chats) {
        if let popup { coordinator.presentNative(popup); return }
        let page = PopupCoordinator.NativePage(title: "Folders…", keepsDraft: { [weak self] in self?.editing != nil })
        page.onDismiss = { [weak self] reason in
            self?.popupRequested = false
            if reason != .dismiss { self?.editing = nil; self?.editingName = "" }
        }
        page.content = { [weak coordinator, weak page] in
            AnyView(FoldersSheet(model: self, entries: entries(), telegram: telegram) {
                guard let page else { return }
                coordinator?.dismiss(page, reason: .applied)
            })
        }
        if coordinator.presentNative(page) { popup = page }
    }
}
