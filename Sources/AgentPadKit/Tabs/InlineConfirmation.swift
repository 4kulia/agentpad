import AppKit
import SwiftUI

/// Runtime only. An address can reveal a live decision, never recreate consent.
@MainActor @Observable
final class ConfirmationCoordinator {
    enum Phase: Equatable { case idle, awaiting, executing, completed, failed(String), cancelled, invalidated }
    struct Context: Equatable {
        var actionID = UUID()
        var tabID: TabID
        var targetID: String
        var scope: OrgKey?
        var generation: String?
        var revision: String?
        var deadline: Date?
        var callerWaiting = false
    }
    private(set) var phase: Phase = .idle
    private(set) var context: Context?
    private(set) var title = ""
    private(set) var consequences = ""
    private(set) var verb = ""
    private(set) var destructive = false
    private(set) var cancelTitle = "Cancel"
    private(set) var isVisible = false
    @ObservationIgnored private var valid: () -> Bool = { false }
    @ObservationIgnored private var operation: (() async throws -> Void)?
    @ObservationIgnored private var completion: ((Bool) -> Void)?
    @ObservationIgnored private weak var initiatingResponder: NSView?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var restoreFocus: () -> Void = {}
    @ObservationIgnored var reveal: () -> Bool = { false }
    @ObservationIgnored var canShow: () -> Bool = { true }

    var isAwaiting: Bool { phase == .awaiting }
    var isExecuting: Bool { phase == .executing }
    var showsBlock: Bool {
        switch phase { case .awaiting, .executing, .failed: true; default: false }
    }

    @discardableResult
    func request(_ context: Context, title: String, consequences: String, verb: String,
                 destructive: Bool = false, cancelTitle: String = "Cancel", stillValid: @escaping () -> Bool,
                 completion: @escaping (Bool) -> Void = { _ in }, operation: @escaping () async throws -> Void) -> Bool {
        guard !showsBlock, stillValid(), context.deadline.map({ $0 > now() }) ?? true else { completion(false); return false }
        isVisible = false
        initiatingResponder = NSApp?.keyWindow?.firstResponder as? NSView
        self.context = context; self.title = title; self.consequences = consequences
        self.verb = verb; self.destructive = destructive; self.cancelTitle = cancelTitle; self.valid = stillValid
        self.completion = completion; self.operation = operation; phase = .awaiting
        watchValidity(context.actionID)
        if let deadline = context.deadline {
            deadlineTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }; self?.validate()
            }
        }
        return true
    }
    private func watchValidity(_ id: UUID) {
        withObservationTracking { _ = valid() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.context?.actionID == id, self.isAwaiting else { return }
                self.validate()
                if self.isAwaiting { self.watchValidity(id) }
            }
        }
    }
    func shown(_ visible: Bool) {
        isVisible = visible && canShow()
        if isVisible, isAwaiting, let context {
            PendingConfirmations.shared.register(context.actionID, tabID: context.tabID, coordinator: self)
        } else if !visible { invalidate() }
    }
    func validate() {
        guard isAwaiting else { return }
        if !valid() || (isVisible && !canShow()) || context?.deadline.map({ $0 <= now() }) == true { invalidate() }
    }
    func confirm() {
        validate()
        guard isAwaiting, isVisible, canShow(), let operation, let id = context?.actionID else { return }
        phase = .executing
        deadlineTask?.cancel()
        PendingConfirmations.shared.end(id)
        Task {
            guard valid(), context?.deadline.map({ $0 > now() }) ?? true else {
                phase = .invalidated; finish(false); return
            }
            do {
                try await operation()
                guard context?.actionID == id else { return }
                phase = .completed; finish(true)
            } catch {
                guard context?.actionID == id else { return }
                // A failed destructive request has no surviving consent.
                phase = .failed(error.localizedDescription); finish(false)
            }
        }
    }
    func cancel() {
        guard isAwaiting || { if case .failed = phase { true } else { false } }() else { return }
        phase = .cancelled; finish(false)
        if let initiatingResponder, initiatingResponder.window?.isKeyWindow == true, !initiatingResponder.isHiddenOrHasHiddenAncestor {
            initiatingResponder.window?.makeFirstResponder(initiatingResponder)
        } else { restoreFocus() }
    }
    func invalidate() {
        guard isAwaiting else { return }
        phase = .invalidated; finish(false)
    }
    private func finish(_ accepted: Bool) {
        isVisible = false
        deadlineTask?.cancel(); deadlineTask = nil
        if let id = context?.actionID { PendingConfirmations.shared.end(id) }
        let callback = completion; completion = nil; operation = nil; valid = { false }
        callback?(accepted)
    }
}

struct InlineConfirmation<Details: View>: View {
    @Bindable var coordinator: ConfirmationCoordinator
    @FocusState private var cancelFocused: Bool
    let details: Details
    init(coordinator: ConfirmationCoordinator, @ViewBuilder details: () -> Details) {
        self.coordinator = coordinator; self.details = details()
    }
    var body: some View {
        if coordinator.showsBlock {
            VStack(alignment: .leading, spacing: 10) {
                Text(coordinator.title).font(.headline)
                Text(coordinator.consequences).fixedSize(horizontal: false, vertical: true)
                details
                if case .failed(let error) = coordinator.phase {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("inline-confirmation-error")
                    Button("Keep editing") { coordinator.cancel() }.focused($cancelFocused)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack { buttons }
                        VStack(alignment: .leading) { buttons }
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.chromeBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.chromeSeparator))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("inline-confirmation")
            .task(id: coordinator.context?.actionID) { coordinator.shown(true); cancelFocused = coordinator.isVisible }
            .onDisappear { coordinator.shown(false) }
            .onExitCommand { coordinator.cancel() }
        }
    }
    @ViewBuilder private var buttons: some View {
        Button(coordinator.cancelTitle) { coordinator.cancel() }.focused($cancelFocused)
            .disabled(coordinator.isExecuting).accessibilityIdentifier("inline-confirmation-cancel")
        Button(coordinator.verb, role: coordinator.destructive ? .destructive : nil) { coordinator.confirm() }
            .disabled(coordinator.isExecuting).accessibilityIdentifier("inline-confirmation-accept")
        if coordinator.isExecuting { ProgressView().controlSize(.small) }
    }
}

extension InlineConfirmation where Details == EmptyView {
    init(coordinator: ConfirmationCoordinator) { self.init(coordinator: coordinator) { EmptyView() } }
}
