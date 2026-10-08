import SwiftUI

struct FileNameDraft: Codable, Equatable {
    enum Kind: String, Codable { case newFile, rename }
    var kind: Kind
    /// A directory for create; the entry itself for rename (never resolve its symlink).
    var path: String
    var name: String
}

@MainActor @Observable
final class FileNameEdit {
    var isVisible = false
    var draft: FileNameDraft? { didSet { changed(draft) } }
    var errors: [String: String] = [:]
    @ObservationIgnored var changed: (FileNameDraft?) -> Void = { _ in }

    static func key(_ url: URL) -> String {
        canonicalDiskPath(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
    }
    func beginNew(in directory: URL) {
        let path = canonicalDiskPath(directory).path
        guard draft == nil else { return }
        draft = FileNameDraft(kind: .newFile, path: path, name: "untitled.txt")
    }
    func beginRename(_ url: URL) {
        guard draft == nil else { return }
        draft = FileNameDraft(kind: .rename, path: Self.key(url), name: url.lastPathComponent)
    }
    func cancel() {
        if let draft { errors[draft.path] = nil }
        draft = nil
    }
    func commit() {
        guard let draft else { return }
        let target = URL(fileURLWithPath: draft.path)
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let directory = draft.kind == .newFile ? target : target.deletingLastPathComponent()
        var problem = FileOperations.renameProblem(name, in: directory, current: draft.kind == .rename ? target.lastPathComponent : nil)
        if problem == nil {
            if draft.kind == .newFile { problem = FileOperations.createExclusively(directory.appendingPathComponent(name)) }
            else { problem = FileOperations.renameItem(target, to: name) }
        }
        errors[draft.path] = problem
        if problem == nil { self.draft = nil }
    }
    func record(_ failures: [FileOperations.Failure]) {
        for (path, failures) in Dictionary(grouping: failures, by: { Self.key($0.url) }) {
            errors[path] = failures.map(\.message).joined(separator: "\n")
        }
    }
    func error(for url: URL) -> String? { errors[Self.key(url)] }
}

struct FileNameField: View {
    @Bindable var edit: FileNameEdit
    @FocusState private var focused: Bool
    var body: some View {
        TextField(edit.draft?.kind == .rename ? "Rename file" : "New file name", text: Binding(
            get: { edit.draft?.name ?? "" }, set: { edit.draft?.name = $0 }))
            .textFieldStyle(.roundedBorder).focused($focused)
            .accessibilityIdentifier("file-name-editor")
            .onSubmit { edit.commit() }
            .onExitCommand { edit.cancel() }
            .onAppear { focused = true }
    }
}

struct FileRowFeedback: View {
    let url: URL
    let edit: FileNameEdit
    var body: some View {
        if edit.draft?.kind == .newFile, edit.draft?.path == FileNameEdit.key(url) {
            FileNameField(edit: edit)
        }
        if let error = edit.error(for: url) {
            Text(error).font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("file-error-" + FileNameEdit.key(url))
        }
    }
}

extension LocalFormTabs {
    func filesModel(_ state: TabState) -> FileTreeModel {
        if let model = state.files { return model }
        let model = FileTreeModel()
        if case .fileName(let draft) = state.draft?.payload { model.nameEdit.draft = draft }
        model.nameEdit.changed = { [weak state] draft in
            guard let state else { return }
            if let draft { state.edit(.fileName(draft)) }
            else { self.clearDraft(state) }
        }
        state.files = model
        return model
    }
    @discardableResult
    func files(_ directory: URL, from store: WorkspaceStore? = nil) -> FileNameEdit? {
        guard let session = router.open(.files(canonicalPath: canonicalDiskPath(directory).path), from: store),
              let state = session.tabState else { return nil }
        return filesModel(state).nameEdit
    }
}

struct FilesTabView: View {
    let state: TabState
    let tabs: LocalFormTabs
    var body: some View {
        if case .files(let path) = state.route, let owner = tabs.owner(state) {
            FileTreeView(store: owner.store, model: tabs.filesModel(state), pinnedRoot: URL(fileURLWithPath: path))
        }
    }
}
