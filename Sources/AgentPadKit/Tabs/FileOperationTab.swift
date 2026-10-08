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
        guard state?.isClosed == false, state?.confirmation.canShow() == true else { stopped = true; return .stop }
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
            }, completion: { [weak self] accepted in if !accepted { self?.stopIfWaiting() } },
            operation: { [weak self] in self?.choose(.replace) })
    }
}

struct FileOperationTab: View {
    @Bindable var batch: FileTransferBatch
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("File operations").font(.title2)
                Text(batch.snapshot.directory.path).textSelection(.enabled)
                if batch.interrupted { Text("Interrupted. Review the files before continuing; nothing resumes automatically.") }
                ForEach(batch.snapshot.sources, id: \.self) { source in
                    VStack(alignment: .leading) {
                        Text(source.path).textSelection(.enabled)
                        Text(status(source)).font(.caption)
                    }
                }
                if let conflict = batch.conflict {
                    Text("Destination: " + conflict.path).textSelection(.enabled)
                    Toggle("Apply to all remaining conflicts", isOn: $batch.applyToAll)
                        .disabled(batch.state?.confirmation.showsBlock == true)
                    ViewThatFits {
                        HStack { choices }
                        VStack(alignment: .leading) { choices }
                    }.disabled(batch.state?.confirmation.showsBlock == true)
                }
                if batch.running { ProgressView().controlSize(.small) }
                else if !batch.snapshot.finished { Button("Review and continue") { batch.resume() } }
                else { Text("Completed") }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private var choices: some View {
        Button("Keep Both") { batch.choose(.keepBoth) }
        Button("Replace…") { batch.replace() }
        Button("Skip") { batch.choose(.skip) }
        Button("Stop") { batch.choose(.stop) }
    }
    private func status(_ source: URL) -> String {
        if batch.snapshot.result.doneSources.contains(source.standardizedFileURL) { return "Completed" }
        if let issue = batch.snapshot.result.issues.first(where: { $0.url == source.standardizedFileURL }) { return issue.message }
        if batch.snapshot.result.skipped.contains(source.standardizedFileURL) { return "Skipped" }
        return "Pending"
    }
}
