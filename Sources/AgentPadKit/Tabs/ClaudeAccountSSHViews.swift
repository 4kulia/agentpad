import SwiftUI

@MainActor @Observable
final class ClaudeAccountSSHSelection {
    var accountID: UUID?
    var replacedAccountID: UUID?
    var lastOperations: [String: RemoteClaudeAccountOperation.Kind] = [:]

    func operation(accountID: UUID, host: String) -> RemoteClaudeAccountOperation.Kind? {
        lastOperations[accountID.uuidString + ":" + host]
    }

    func remember(_ kind: RemoteClaudeAccountOperation.Kind, accountID: UUID, host: String) {
        lastOperations[accountID.uuidString + ":" + host] = kind
    }
}

struct RemoteClaudeAccountBlock: Equatable {
    let accountID: UUID
    let accountName: String
    let host: String
    let status: RemoteClaudeAccountState
    let profileName: String
    var folder: String = ""
}

extension RemoteClaudeAccountState {
    var isWorking: Bool { self == .checking || self == .installing || self == .removing }
    var hasStoredCopy: Bool { self == .current || self == .stale }
    var title: String {
        switch self {
        case .unchecked: "Not checked"
        case .checking: "Checking…"
        case .notInstalled: "Not installed"
        case .current: "Installed"
        case .stale: "Out of date"
        case .installing: "Installing…"
        case .removing: "Removing…"
        case .failed: "Couldn’t check host"
        }
    }
    @MainActor var tint: Color {
        switch self {
        case .current: Theme.gitInsertion
        case .stale: Theme.resolved.isLight ? Color(red: 149 / 255, green: 96 / 255, blue: 23 / 255) : Theme.activityAttention
        case .failed: Theme.gitDeletion
        default: Theme.chromeMuted
        }
    }
}

struct ClaudeAccountSSHStatus: View {
    let state: RemoteClaudeAccountState
    var title: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(state.isFailure ? "!" : state == .notInstalled || state == .unchecked ? "○" : "●").font(Theme.display(10))
            Text(title ?? state.title)
        }.foregroundStyle(state.tint).font(Theme.display(11))
    }
}

private struct ClaudeAccountSSHSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.display(11)).foregroundStyle(Theme.chromeForeground)
            .padding(.horizontal, 10).padding(.vertical, 5).frame(minHeight: 27)
            .background(Theme.chromeHover.opacity(configuration.isPressed ? 1 : 0.15), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.chromeHairline))
            .contentShape(RoundedRectangle(cornerRadius: 6)).opacity(enabled ? 1 : 0.4)
    }
}

struct ClaudeAccountSSHHostsView: View {
    let account: ClaudeAccount
    let agents: [String]
    let hosts: [String]
    let service: RemoteClaudeAccountService
    let selection: ClaudeAccountSSHSelection
    let onReplace: () -> Void
    let onAction: (String, RemoteClaudeAccountOperation.Kind) -> Void

    private var staleCount: Int { hosts.filter { service.state(accountID: account.id, host: $0) == .stale }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(String(account.name.prefix(1))).font(Theme.display(16))
                    .frame(width: 35, height: 35).foregroundStyle(Theme.claudeAccount)
                    .background(Theme.claudeAccount.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.name).font(Theme.display(13, weight: .semibold))
                    Text((selection.replacedAccountID == account.id ? "Token replaced on this Mac" : "Token saved on this Mac")
                        + (agents.isEmpty ? "" : " · " + agents.joined(separator: ", ")))
                        .font(Theme.display(10)).foregroundStyle(Theme.chromeMuted)
                }
                Spacer()
                Button("Replace token…", action: onReplace).controlSize(.small)
            }
            if selection.replacedAccountID == account.id {
                ClaudeAccountSSHBanner(
                    title: staleCount == 0 ? "New token saved on this Mac." : "New token saved. \(staleCount) \(staleCount == 1 ? "host still needs" : "hosts still need") an update.",
                    detail: "Nothing is sent automatically. New sessions require the current token on their host.",
                    color: RemoteClaudeAccountState.stale.tint)
            }
            HStack(spacing: 12) {
                Text("SSH hosts").font(Theme.display(12, weight: .semibold))
                Text("\(hosts.count) \(hosts.count == 1 ? "destination" : "destinations")")
                    .font(Theme.display(10)).foregroundStyle(Theme.chromeMuted)
                Spacer()
                Button("Refresh status") {
                    Task { for host in hosts { _ = await service.check(accountID: account.id, host: host) } }
                }.controlSize(.small).disabled(hosts.contains { service.state(accountID: account.id, host: $0).isWorking })
                    .accessibilityIdentifier("claude-ssh-refresh")
            }.padding(.top, 5)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    Text("SSH host").frame(minWidth: 105, alignment: .leading)
                    Text("\(account.name) token").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Actions").frame(maxWidth: .infinity, alignment: .trailing)
                }.font(Theme.display(10)).foregroundStyle(Theme.chromeMuted).padding(.bottom, 9)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(hosts, id: \.self) { host in
                    let state = service.state(accountID: account.id, host: host)
                    GridRow {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(host).fontWeight(.semibold)
                            Text(host.contains("@") ? host : "SSH destination")
                                .font(Theme.display(10)).foregroundStyle(Theme.chromeMuted)
                        }.frame(minWidth: 105, alignment: .leading)
                        VStack(alignment: .leading, spacing: 5) {
                            ClaudeAccountSSHStatus(state: state, title: statusTitle(state, host: host))
                            Text(statusDetail(state, host: host)).font(Theme.display(10)).foregroundStyle(Theme.chromeMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        hostActions(state, host: host).frame(maxWidth: .infinity, alignment: .trailing)
                    }.font(Theme.display(11)).padding(.vertical, 12)
                        .accessibilityElement(children: .contain).accessibilityIdentifier("claude-ssh-host-\(host)")
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
            if hosts.isEmpty {
                Text("Create an SSH workspace to install this account on a trusted host.")
                    .foregroundStyle(Theme.chromeMuted).padding(.vertical, 10)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(selection.replacedAccountID == account.id
                    ? "Running sessions keep the token they started with. Restart them after updating the host."
                    : "Install once on each trusted host. “Installed” means the token is stored; sign-in is checked when Claude starts.")
                Text("Host status is specific to the SSH user and destination. Refresh status to check the saved copy.")
            }.font(Theme.display(10)).foregroundStyle(Theme.chromeMuted).fixedSize(horizontal: false, vertical: true)
        }.buttonStyle(ClaudeAccountSSHSecondaryButtonStyle()).accessibilityIdentifier("claude-ssh-hosts")
    }

    private func statusTitle(_ state: RemoteClaudeAccountState, host: String) -> String? {
        guard state.isFailure, let kind = selection.operation(accountID: account.id, host: host) else { return nil }
        return "\(kind.verb) failed"
    }
    private func statusDetail(_ state: RemoteClaudeAccountState, host: String) -> String {
        switch state {
        case .current: "Current token · checked this session"
        case .notInstalled: "\(account.name) has no token on this host"
        case .stale: "Token replaced on this Mac"
        case .failed: state.failureMessage ?? "Check connection and access"
        case .unchecked: "No status has been read from this host"
        case .checking: "Reading the non-secret token revision"
        case .installing: "Saving this account on the host"
        case .removing: "Deleting this account’s saved file"
        }
    }
    @ViewBuilder private func hostActions(_ state: RemoteClaudeAccountState, host: String) -> some View {
        HStack(spacing: 8) {
            if state == .current || state == .unchecked || state.isFailure {
                Button(state == .unchecked ? "Check status" : "Check again") {
                    Task { _ = await service.check(accountID: account.id, host: host) }
                }
            }
            if state != .current && state != .unchecked && !state.isWorking {
                let kind: RemoteClaudeAccountOperation.Kind = state == .stale ? .update
                    : state.isFailure ? selection.operation(accountID: account.id, host: host) ?? .install : .install
                Button(state.isFailure ? "Retry…" : state == .stale ? "Update…" : "Install…") { onAction(host, kind) }
                    .accessibilityIdentifier("claude-ssh-install-\(host)")
            }
            if state.hasStoredCopy || state.isFailure || state == .unchecked {
                Button("Remove…") { onAction(host, .remove) }.buttonStyle(.plain).foregroundStyle(Theme.chromeMuted)
                    .accessibilityIdentifier("claude-ssh-remove-\(host)")
            }
            if state.isWorking { ProgressView().controlSize(.mini) }
        }.controlSize(.small)
    }
}

@MainActor @Observable
final class RemoteClaudeAccountOperation {
    enum Kind: Equatable {
        case install, update, remove
        var verb: String { switch self { case .install: "Install"; case .update: "Update"; case .remove: "Remove" } }
        var title: String { switch self { case .install: "Install Claude account"; case .update: "Update host token"; case .remove: "Remove from host" } }
    }
    let account: ClaudeAccount
    let host: String
    let kind: Kind
    let agentName: String?
    let canStartAfterInstall: Bool
    var startAfterInstall = false
    private(set) var busy = false
    private(set) var failed = false
    var failureTitle = "The SSH operation couldn’t be completed."
    var failureDetail = "Check the SSH connection and the remote user’s access to the private account folder, then retry."
    var locksDismissal: Bool { busy || (!failed && kind != .install) }
    var primaryTitle: String {
        if kind == .remove { return "Remove from host" }
        if startAfterInstall, let agentName { return "\(kind.verb) and start \(agentName)" }
        return "\(kind.verb) on \(host)"
    }
    var failureHeading: String {
        "Couldn’t confirm \(account.name)’s \(kind == .remove ? "removal from" : kind == .update ? "update on" : "installation on") \(host)"
    }

    init(account: ClaudeAccount, host: String, kind: Kind, agentName: String? = nil, canStartAfterInstall: Bool = false) {
        self.account = account; self.host = host; self.kind = kind; self.agentName = agentName
        self.canStartAfterInstall = canStartAfterInstall
    }

    func perform(accounts: ClaudeAccountStore, service: RemoteClaudeAccountService) async -> Bool {
        guard !busy else { return false }
        guard accounts.account(account.id)?.credentialRevision == account.credentialRevision else {
            failed = true
            failureTitle = "The account changed while this confirmation was open."
            failureDetail = "Go back to hosts and open the action again to review the current account."
            return false
        }
        busy = true; failed = false
        let result = kind == .remove
            ? await service.remove(accountID: account.id, host: host, expectedRevision: account.credentialRevision)
            : await service.install(accountID: account.id, host: host, expectedRevision: account.credentialRevision)
        busy = false
        let succeeded = kind == .remove ? result == .notInstalled : result == .current
        failed = !succeeded
        if case .failed(let reason) = result {
            failureDetail = reason.message
            failureTitle = switch reason {
            case .permissions: "Permission denied"
            case .connection: "SSH connection failed"
            case .localToken: "Local token unavailable"
            case .invalidRecord: "Remote account file unavailable"
            case .missingAccount: "Account no longer available"
            case .changedAccount: "The account changed while this confirmation was open."
            }
        }
        return succeeded
    }
}

struct ClaudeAccountSSHBanner: View {
    let title: String
    let detail: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).fontWeight(.semibold)
            Text(detail)
        }.font(Theme.display(11)).foregroundStyle(color).lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13).padding(.vertical, 11)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ClaudeAccountSSHFact: View {
    let label: String
    let value: String
    var detail: String? = nil
    var tagged = false
    var mono = false
    var body: some View {
        HStack(alignment: .top, spacing: 15) {
            Text(label).foregroundStyle(Theme.chromeMuted).frame(width: 105, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if tagged {
                    Text(value).font(Theme.display(10, weight: .semibold)).foregroundStyle(Theme.claudeAccount)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.claudeAccount.opacity(0.12), in: Capsule())
                } else { Text(value).font(mono ? Theme.mono(11) : Theme.display(12)) }
                if let detail { Text(detail).font(Theme.display(10)).foregroundStyle(Theme.chromeMuted) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.font(Theme.display(12)).fixedSize(horizontal: false, vertical: true)
    }
}

struct RemoteClaudeAccountOperationView: View {
    @Bindable var operation: RemoteClaudeAccountOperation
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onHosts: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PopupScrollBody(maxHeight: 600) {
                VStack(alignment: .leading, spacing: 18) {
                    if operation.failed { failureBody } else if operation.kind == .remove { removeBody } else { installBody }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }.font(Theme.display(12)).foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground)
            .accessibilityElement(children: .contain).accessibilityIdentifier("claude-ssh-operation")
    }
    private var installBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("\(operation.kind.verb) \(operation.account.name) on \(operation.host)?",
                detail: operation.kind == .update
                    ? "Replace the older token stored on this host with the token now saved on this Mac."
                    : "A copy of \(operation.account.name)’s token will be stored on this host, so \(operation.agentName ?? "agents assigned to this account") can use the \(operation.account.name) subscription over SSH.")
            VStack(spacing: 14) {
                ClaudeAccountSSHFact(label: "Account", value: operation.account.name,
                    detail: "Saved on this Mac" + (operation.agentName.map { " · used by \($0)" } ?? ""), tagged: true)
                ClaudeAccountSSHFact(label: "SSH destination", value: operation.host, detail: "Uses your existing SSH configuration")
                ClaudeAccountSSHFact(label: "Access", value: "The remote user’s private account file", detail: "Stored in the remote user’s home folder")
            }
            ClaudeAccountSSHBanner(title: "Only install on a host you trust.",
                detail: "The host’s administrator and programs running as the remote user can read this token. Removing the file later does not revoke it.",
                color: RemoteClaudeAccountState.stale.tint)
            step("1", title: "Send \(operation.kind == .update ? "the replacement" : "the token") once through the encrypted SSH connection.",
                detail: "The transfer stays out of the terminal and command history.")
            step("2", title: "Future launches use the copy already on \(operation.host).",
                detail: operation.kind == .update ? "Running sessions keep their previous token until restarted." : "The token is not resent when the agent starts.")
            if operation.canStartAfterInstall, let agentName = operation.agentName {
                Toggle("Start \(agentName) after installation", isOn: $operation.startAfterInstall)
                    .toggleStyle(.checkbox).disabled(operation.busy).accessibilityIdentifier("claude-ssh-start-after-install")
            }
        }
    }
    private var removeBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Remove \(operation.account.name) from \(operation.host)?",
                detail: "Delete this account’s saved token from \(operation.host). New \(operation.account.name) sessions on this host will need an installation before they can start.")
            VStack(spacing: 14) {
                ClaudeAccountSSHFact(label: "Account", value: operation.account.name, tagged: true)
                ClaudeAccountSSHFact(label: "SSH destination", value: operation.host)
                ClaudeAccountSSHFact(label: "Remove", value: "This account’s remote token", detail: "\(operation.account.name) on this Mac and other hosts is kept.")
            }
            ClaudeAccountSSHBanner(title: "Running sessions can keep using their token.",
                detail: "This removes the saved file. It does not stop sessions, erase backups or revoke the token with Claude.", color: RemoteClaudeAccountState.stale.tint)
        }
    }
    private var failureBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            ClaudeAccountSSHStatus(state: .failed(.permissions), title: "\(operation.kind.verb) failed")
            heading(operation.failureHeading,
                detail: "AgentPad couldn’t confirm that the private account record was \(operation.kind == .remove ? "removed" : "saved") on this host.")
            ClaudeAccountSSHBanner(title: operation.failureTitle, detail: operation.failureDetail, color: RemoteClaudeAccountState.failed(.permissions).tint)
            VStack(spacing: 14) {
                ClaudeAccountSSHFact(label: "Destination", value: operation.host)
                ClaudeAccountSSHFact(label: "Operation", value: operation.kind == .remove ? "Remove private account record" : "\(operation.kind.verb) private account record", detail: "~/.agentpad/claude-accounts/")
                ClaudeAccountSSHFact(label: "Result", value: "Host status must be checked", detail: "\(operation.agentName ?? "The agent") has not started on \(operation.host).")
            }
            Text("Check the connection and remote folder access, then retry. New sessions stay blocked until the current token is installed.")
                .foregroundStyle(Theme.chromeMuted).fixedSize(horizontal: false, vertical: true).lineSpacing(4)
        }
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Text(operation.failed ? "The host row keeps this failure and its reason."
                : operation.kind == .remove ? "Choose Cancel or Remove from host." : "Applies only to this account on this host.")
                .font(Theme.display(10)).foregroundStyle(Theme.chromeMuted).frame(maxWidth: .infinity, alignment: .leading)
            Button(operation.failed ? "Back to hosts" : "Cancel", action: operation.failed ? onHosts : onCancel)
                .buttonStyle(ClaudeAccountSSHSecondaryButtonStyle())
                .disabled(operation.busy).accessibilityIdentifier("claude-ssh-cancel")
            if operation.kind == .remove {
                confirmButton.buttonStyle(PopupDestructiveButtonStyle())
            } else {
                confirmButton.buttonStyle(PopupPrimaryButtonStyle())
            }
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }
    private var confirmButton: some View {
        Button(operation.busy ? "\(operation.kind.verb)…" : operation.failed ? "Retry \(operation.kind.verb.lowercased())…" : operation.primaryTitle,
            role: operation.kind == .remove ? .destructive : nil, action: onConfirm)
            .disabled(operation.busy).accessibilityIdentifier("claude-ssh-confirm")
    }
    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(Theme.display(20, weight: .semibold))
            Text(detail).foregroundStyle(Theme.chromeMuted).lineSpacing(5)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func step(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(Theme.display(10)).foregroundStyle(Theme.chromeMuted).frame(width: 21, height: 21)
                .overlay(Circle().strokeBorder(Theme.chromeHairline))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).fontWeight(.medium)
                Text(detail).foregroundStyle(Theme.chromeMuted)
            }.font(Theme.display(11)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RemoteClaudeAccountBlockedView: View {
    let block: RemoteClaudeAccountBlock
    let onInstall: () -> Void
    let onManage: () -> Void
    var onStart: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    private var stale: Bool { block.status == .stale }
    private var ready: Bool { block.status == .current }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ClaudeAccountSSHStatus(state: .stale, title: "\(block.profileName) has not started")
                Text(ready ? "\(block.accountName) is ready on \(block.host)" : stale ? "\(block.accountName)’s token is out of date on \(block.host)" : block.status.isFailure ? "Couldn’t check \(block.accountName) on \(block.host)" : "\(block.accountName) isn’t installed on \(block.host)")
                    .font(Theme.display(22, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(ready ? "The current token is stored on this host. Start \(block.profileName) when you’re ready." : stale ? "\(block.accountName)’s token was replaced on this Mac. Update the copy on \(block.host) before starting this agent."
                    : block.status.failureMessage ??
                    "This profile uses \(block.accountName). Install its token on this SSH host to start \(block.profileName) here.")
                    .foregroundStyle(Theme.chromeMuted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                Divider()
                VStack(spacing: 10) {
                    ClaudeAccountSSHFact(label: "Agent", value: "\(block.profileName) · Claude Code")
                    ClaudeAccountSSHFact(label: "Claude account", value: block.accountName, tagged: true)
                    ClaudeAccountSSHFact(label: "SSH destination", value: block.host)
                    if !block.folder.isEmpty { ClaudeAccountSSHFact(label: "Folder", value: block.folder, mono: true) }
                }
                Divider()
                Text("AgentPad won’t switch this session to Main account.").foregroundStyle(Theme.chromeMuted)
                HStack(spacing: 8) {
                    Button(ready ? "Start \(block.profileName)" : block.status.isFailure ? "Check again" : "\(stale ? "Update" : "Install") on \(block.host)…",
                        action: ready ? onStart ?? onInstall : block.status.isFailure ? onRetry ?? onInstall : onInstall)
                        .buttonStyle(PopupPrimaryButtonStyle()).accessibilityIdentifier("claude-ssh-blocked-install")
                    Button("Manage \(block.accountName) account", action: onManage)
                        .buttonStyle(ClaudeAccountSSHSecondaryButtonStyle())
                        .accessibilityIdentifier("claude-ssh-blocked-manage")
                }.padding(.top, 3)
                Text(stale ? "New sessions wait for the current token. Running sessions keep their previous token."
                    : "The token is sent once at installation. Future starts use the stored copy.")
                    .font(Theme.display(10)).foregroundStyle(Theme.chromeMuted).fixedSize(horizontal: false, vertical: true)
            }.font(Theme.display(12)).padding(.horizontal, 26).padding(.vertical, 24)
                .frame(maxWidth: 595, alignment: .leading).background(Theme.chromeHover.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.chromeHairline))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 36).padding(.vertical, 42)
        }.foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground)
            .accessibilityElement(children: .contain).accessibilityIdentifier("claude-ssh-blocked")
    }
}

extension WorkspaceStore {
    var remoteClaudeAccountHosts: [String] {
        Array(Set(profileStores.flatMap(\.workspaces).compactMap(\.sshRemoteHost))).sorted()
    }

    func openRemoteClaudeAccountManagement(accountID: UUID) {
        popups.claudeAccountSSHSelection.accountID = accountID
        popups.presentSettings(section: .claudeAccounts)
    }

    func openRemoteClaudeAccountInstall(accountID: UUID, host: String, profileName: String? = nil, onInstalled: (() -> Void)? = nil) {
        guard let account = agentProfiles.claudeAccounts.account(accountID) else { return }
        let kind: RemoteClaudeAccountOperation.Kind = agentProfiles.remoteClaudeAccounts.state(accountID: accountID, host: host) == .stale ? .update : .install
        let name = profileName ?? agentProfiles.profiles.first { $0.claudeAccountID == accountID }?.name
        popups.presentRemoteClaudeAccountOperation(account: account, host: host, kind: kind,
            profiles: agentProfiles, agentName: onInstalled == nil ? nil : name, onInstalled: onInstalled)
    }
}

extension PopupCoordinator {
    func presentRemoteClaudeAccountOperation(account: ClaudeAccount, host: String, kind: RemoteClaudeAccountOperation.Kind,
        profiles: AgentProfileStore, agentName: String? = nil, onInstalled: (() -> Void)? = nil) {
        let name = agentName ?? profiles.profiles.first { $0.claudeAccountID == account.id }?.name
        let operation = RemoteClaudeAccountOperation(account: account, host: host, kind: kind, agentName: name,
            canStartAfterInstall: onInstalled != nil)
        let native = NativePage(title: kind.title, width: 620, locksDismissal: { operation.locksDismissal })
        native.content = { [weak self, weak native] in
            AnyView(RemoteClaudeAccountOperationView(operation: operation,
                onCancel: { guard let native else { return }; self?.dismiss(native, reason: .cancel) },
                onConfirm: {
                    guard !operation.busy else { return }
                    self?.claudeAccountSSHSelection.remember(kind, accountID: account.id, host: host)
                    Task {
                        if await operation.perform(accounts: profiles.claudeAccounts, service: profiles.remoteClaudeAccounts) {
                            if let native { self?.dismiss(native, reason: .applied) }
                            if operation.startAfterInstall && kind != .remove { onInstalled?() }
                        }
                    }
                }, onHosts: {
                    guard let native else { return }
                    self?.dismiss(native, reason: .cancel)
                    self?.ownerStore?.openRemoteClaudeAccountManagement(accountID: account.id)
                }))
        }
        presentNative(native)
    }
}
