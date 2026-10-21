import SwiftUI

struct FileTransferSnapshot: Codable, Equatable {
    let sources: [URL]
    let directory: URL
    let mode: FileOperations.PasteMode
    var result = FileOperations.TransferResult()
    var finished = false
}

@MainActor @Observable
final class FileTransferBatch {
    var snapshot: FileTransferSnapshot
    private(set) var running = false
    private(set) var conflict: URL?
    var applyToAll = false
    var interrupted = false
    private var allChoice: FileOperations.ConflictChoice?
    private var decision: CheckedContinuation<FileOperations.ConflictChoice, Never>?
    private var stopped = false
    weak var state: TabState?
    let tabID: TabID
    var fileManager = TransferFileIO()
    var onResult: (FileOperations.TransferResult) -> Void = { _ in }

    init(_ snapshot: FileTransferSnapshot, state: TabState, tabID: TabID, restored: Bool = false) {
        self.snapshot = snapshot; self.state = state; self.tabID = tabID
        interrupted = restored && !snapshot.finished
    }

    var completedCount: Int { snapshot.result.doneSources.count + snapshot.result.skipped.count }
    var progressTitle: String {
        if snapshot.finished { return "Files completed" }
        if conflict != nil { return "Files waiting for a choice" }
        if interrupted { return "File operation interrupted" }
        return "\(snapshot.mode == .move ? "Moving" : "Copying") \(completedCount) of \(snapshot.sources.count)…"
    }
    var conflictingSource: URL? {
        guard let conflict else { return nil }
        let resolved = Set(snapshot.result.doneSources + snapshot.result.skipped + snapshot.result.issues.map(\.url))
        return snapshot.sources.first {
            $0.lastPathComponent == conflict.lastPathComponent && !resolved.contains($0.standardizedFileURL)
        }
    }

    func start() async -> FileOperations.TransferResult {
        guard !running, !snapshot.finished, !interrupted else { return snapshot.result }
        running = true; stopped = false; allChoice = nil
        let previous = snapshot.result
        let completed = Set(previous.doneSources + previous.skipped)
        let pending = snapshot.sources.filter { !completed.contains($0.standardizedFileURL) }
        let result = await FileOperations.transfer(pending, into: snapshot.directory, mode: snapshot.mode,
            fileManager: fileManager, progress: { [weak self] result in await self?.update(result, previous: previous) },
            resolve: { [weak self] url in await self?.resolve(url) ?? .stop })
        update(result, previous: previous)
        running = false
        snapshot.finished = !stopped && snapshot.result.issues.isEmpty
        interrupted = stopped
        persist()
        onResult(snapshot.result)
        return snapshot.result
    }

    func resume() {
        guard !running else { return }
        interrupted = false
        Task { _ = await start() }
    }

    private func update(_ result: FileOperations.TransferResult, previous: FileOperations.TransferResult) {
        snapshot.result = result
        snapshot.result.done = previous.done + result.done
        snapshot.result.doneSources = previous.doneSources + result.doneSources
        snapshot.result.skipped = previous.skipped + result.skipped
        persist()
    }
    private func persist() { state?.navigation.fileTransfer = snapshot; state?.changed() }

    private func resolve(_ url: URL) async -> FileOperations.ConflictChoice {
        guard !stopped else { return .stop }
        if let allChoice { return allChoice }
        guard let state, !state.isClosed, state.isPopup || state.confirmation.canShow() else { stopped = true; return .stop }
        conflict = url; applyToAll = false
        return await withCheckedContinuation { decision = $0 }
    }
    func choose(_ choice: FileOperations.ConflictChoice) {
        guard let decision else { return }
        self.decision = nil; conflict = nil
        if choice == .stop { stopped = true }
        else if applyToAll { allChoice = choice }
        decision.resume(returning: choice)
    }
    func stopIfWaiting() {
        guard decision != nil else { return }
        choose(.stop)
    }
    func replace() {
        guard let conflict, let state else { return }
        let stamp = FileIdentity(conflict)
        state.confirmation.request(.init(tabID: tabID, targetID: conflict.path),
            title: "Replace “\(conflict.lastPathComponent)”?",
            consequences: "The new item is staged first, then the existing item goes to the Trash."
                + (applyToAll ? " This choice applies only to remaining conflicts." : " This choice applies to this conflict."),
            verb: "Replace", destructive: true, stillValid: { [weak self] in
                self?.conflict == conflict && FileIdentity(conflict) == stamp
            }, operation: { [weak self] in self?.choose(.replace) })
    }
}

struct FileOperationTab: View {
    @Bindable var batch: FileTransferBatch
    var body: some View {
        VStack(spacing: 0) {
            PopupScrollBody {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("File operations").font(.title3.weight(.semibold))
                        Text(batch.snapshot.directory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let conflict = batch.conflict {
                        conflictBody(conflict)
                    } else {
                        progressBody
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("file-operation-content")
    }

    private func conflictBody(_ conflict: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(conflict.lastPathComponent).font(.headline)
                if let source = batch.conflictingSource {
                    Text(source.path).font(.caption.monospaced()).textSelection(.enabled)
                }
                Text("Pending · an item with this name already exists.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(Theme.chromeHover.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.chromeHairline))
            Text("Destination: " + conflict.path).font(.caption.monospaced()).textSelection(.enabled)
            Toggle("Apply to all remaining conflicts", isOn: $batch.applyToAll)
                .disabled(batch.state?.confirmation.showsBlock == true)
                .accessibilityIdentifier("file-operation-apply-all")
            note("The \(batch.snapshot.mode == .move ? "move" : "copy") is waiting for your choice. You can close and return to this operation.")
        }
    }

    private var progressBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(batch.progressTitle).font(.headline)
                Spacer()
                Text(batch.snapshot.finished ? "Completed" : batch.interrupted ? "Interrupted" : batch.running ? "In progress" : "Ready")
                    .font(.caption).foregroundStyle(batch.snapshot.finished ? Color.green : Color.accentColor)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            }
            ProgressView(value: Double(batch.completedCount), total: Double(max(1, batch.snapshot.sources.count)))
                .accessibilityLabel("File \(batch.snapshot.mode == .move ? "move" : "copy")")
            if batch.interrupted {
                Text("Interrupted. Review the files before continuing; nothing resumes automatically.")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(batch.snapshot.sources, id: \.self) { source in
                VStack(spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(source.lastPathComponent).textSelection(.enabled).help(source.path)
                        Spacer()
                        Text(status(source)).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }
            if !batch.running, !batch.snapshot.finished {
                Button("Review and continue") { batch.resume() }
                    .disabled(batch.state?.confirmation.showsBlock == true)
                    .accessibilityIdentifier("file-operation-resume")
            }
            note(batch.snapshot.finished
                ? "The operation is complete. Close this popup when you are finished reviewing the files."
                : "Close this popup to keep working. The operation stays available; its status-bar item brings you back.")
        }
    }

    @ViewBuilder private var actions: some View {
        if batch.conflict != nil {
            Group {
                Button("Stop") { batch.choose(.stop) }.accessibilityIdentifier("file-operation-stop")
                Button("Skip") { batch.choose(.skip) }.accessibilityIdentifier("file-operation-skip")
                Spacer()
                Button("Replace…", role: .destructive) { batch.replace() }
                    .buttonStyle(PopupDestructiveButtonStyle()).accessibilityIdentifier("file-operation-replace")
                Button("Keep Both") { batch.choose(.keepBoth) }
                    .buttonStyle(PopupPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("file-operation-keep-both")
            }.disabled(batch.state?.confirmation.showsBlock == true)
        } else {
            if batch.running { Text("\(batch.snapshot.mode == .move ? "Moving" : "Copying") continues after closing.").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(batch.snapshot.finished ? "Done" : "Close") {
                guard let state = batch.state, let owner = SupportTabs.shared.owner(state) else { return }
                owner.store.popups.dismiss(owner.session, reason: batch.snapshot.finished ? .applied : .dismiss)
            }.buttonStyle(PopupPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(batch.snapshot.finished ? "file-operation-done" : "file-operation-close")
        }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    }
    private func status(_ source: URL) -> String {
        if batch.snapshot.result.doneSources.contains(source.standardizedFileURL) { return "Completed" }
        if let issue = batch.snapshot.result.issues.first(where: { $0.url == source.standardizedFileURL }) { return issue.message }
        if batch.snapshot.result.skipped.contains(source.standardizedFileURL) { return "Skipped" }
        return "Pending"
    }
}

struct PopupFileOperationsStatus: View {
    let coordinator: PopupCoordinator
    private var operations: [Session] { coordinator.sessions.filter { $0.tabState?.fileOperation != nil } }

    var body: some View {
        if !operations.isEmpty {
            Menu {
                ForEach(operations) { operation in
                    Button(title(operation)) {
                        if let route = operation.toolRoute { coordinator.present(route) }
                    }
                }
            } label: {
                Label(operations.count == 1 ? title(operations[0]) : "File operations · \(operations.count)",
                      systemImage: "doc.on.doc")
            }.menuStyle(.borderlessButton).fixedSize()
                .help("Reopen file operations")
                .accessibilityIdentifier("file-operations-status")
        }
    }

    private func title(_ session: Session) -> String {
        session.tabState?.fileOperation?.progressTitle ?? "File operations"
    }
}
