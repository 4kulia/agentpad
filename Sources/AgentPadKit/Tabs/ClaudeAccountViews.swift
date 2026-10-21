import SwiftUI

@MainActor @Observable
final class ClaudeAccountForm {
    let profiles: AgentProfileStore
    let replacing: UUID?
    var name: String
    var token = ""
    private(set) var problem: String?
    var isReplacing: Bool { replacing != nil }

    init(profiles: AgentProfileStore, replacing: UUID? = nil) {
        self.profiles = profiles
        self.replacing = replacing
        name = replacing.flatMap { profiles.claudeAccounts.account($0)?.name } ?? ""
    }

    func apply() -> ClaudeAccount? {
        do {
            let account: ClaudeAccount
            if let replacing {
                try profiles.claudeAccounts.replaceToken(id: replacing, token: token)
                guard let saved = profiles.claudeAccounts.account(replacing) else {
                    throw ClaudeAccountStore.Problem.missingAccount
                }
                account = saved
            } else {
                guard let title = normalizedTitle(name), InlineNameEdit.problem(title) == nil else {
                    problem = "Enter a single-line account name."
                    return nil
                }
                account = try profiles.claudeAccounts.add(name: title, token: token)
            }
            token = ""
            problem = nil
            return account
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    func cancel() {
        token = ""
        name = replacing.flatMap { profiles.claudeAccounts.account($0)?.name } ?? ""
        problem = nil
    }
}

struct ClaudeAccountFormView: View {
    @Bindable var form: ClaudeAccountForm
    let onCancel: () -> Void
    let onComplete: (ClaudeAccount) -> Void
    var onOpenTerminal: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(form.isReplacing ? "Replace token" : "Add Claude account")
                            .font(Theme.display(18, weight: .semibold))
                        Text("Agents you assign to it run on that account’s subscription.")
                            .font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name").foregroundStyle(Theme.chromeMuted)
                        TextField("Work", text: $form.name)
                            .textFieldStyle(.roundedBorder)
                            .disabled(form.isReplacing)
                            .accessibilityIdentifier("claude-account-name")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Token").foregroundStyle(Theme.chromeMuted)
                        SecureField("Paste token", text: $form.token)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("claude-account-token")
                        Text("In your browser, sign in to claude.ai with that account. Then run claude setup-token in a terminal tab and paste the token it prints. It is valid for one year.")
                            .font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Stored in Keychain, never shown again.")
                        .font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
                    if let problem = form.problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("claude-account-error")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            Divider()
            HStack {
                if let onOpenTerminal {
                    Button("Open terminal tab", action: onOpenTerminal)
                        .accessibilityIdentifier("claude-account-open-terminal")
                }
                Spacer()
                Button("Cancel") { form.cancel(); onCancel() }
                    .accessibilityIdentifier("claude-account-cancel")
                Button(form.isReplacing ? "Save" : "Add") {
                    if let account = form.apply() { onComplete(account) }
                }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("claude-account-apply")
            }.padding(.horizontal, 20).padding(.vertical, 13)
        }.font(Theme.display(12)).foregroundStyle(Theme.chromeForeground)
            .background(Theme.chromeBackground)
            .environment(\.colorScheme, Theme.chromeColorScheme)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("claude-account-form")
    }
}

struct ClaudeAccountsSettingsView: View {
    let profiles: AgentProfileStore
    @Bindable var selection: ClaudeAccountSSHSelection
    var hosts: [String] = []
    let onAdd: () -> Void
    let onReplace: (UUID) -> Void
    let onConfirmRemove: (ClaudeAccount, @escaping () throws -> Void) -> Void
    var onSSHAction: (ClaudeAccount, String, RemoteClaudeAccountOperation.Kind) -> Void = { _, _, _ in }

    static func expires(_ account: ClaudeAccount, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .year, value: 1, to: account.createdAt) ?? account.createdAt
    }

    private func agents(_ id: UUID?) -> [AgentProfile] {
        profiles.profiles.filter {
            $0.claudeAccountID == id && (id != nil || $0.templateID == AgentTemplate.claudeCodeID)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude accounts").font(Theme.display(18, weight: .semibold))
                Text("Choose the subscription each agent uses, on this Mac and over SSH.")
                    .font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    accountTab("Main account", id: nil)
                    ForEach(profiles.claudeAccounts.list) { account in accountTab(account.name, id: account.id) }
                    Button("＋ Add account…", action: onAdd).buttonStyle(.plain).foregroundStyle(Theme.chromeMuted)
                        .padding(.horizontal, 12).accessibilityIdentifier("claude-account-add")
                }
            }.scrollIndicators(.hidden).padding(.bottom, -12)
            Divider()
            if let account = selection.accountID.flatMap({ profiles.claudeAccounts.account($0) }) {
                ClaudeAccountSSHHostsView(account: account, agents: agents(account.id).map(\.name), hosts: hosts,
                    service: profiles.remoteClaudeAccounts, selection: selection, onReplace: { onReplace(account.id) },
                    onAction: { host, kind in onSSHAction(account, host, kind) })
                HStack {
                    Text("Expires \(Self.expires(account).formatted(date: .abbreviated, time: .omitted))")
                        .font(Theme.display(10)).foregroundStyle(Theme.chromeMuted)
                    Spacer()
                    Button("Remove account from this Mac…", role: .destructive) {
                        onConfirmRemove(account) {
                            try profiles.claudeAccounts.remove(id: account.id)
                            selection.accountID = nil
                        }
                    }.controlSize(.small)
                        .disabled(!agents(account.id).isEmpty)
                        .help(agents(account.id).isEmpty ? "Remove this account from this Mac" : "Move agents to another account first")
                        .accessibilityIdentifier("claude-account-remove-\(account.id)")
                }.padding(.top, 12)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Main account").font(Theme.display(13, weight: .semibold))
                    Text("Main uses the Claude Code login on this Mac. In an SSH workspace, it uses the server’s Claude Code login.")
                    Text("\(agents(nil).count) \(agents(nil).count == 1 ? "agent" : "agents") · Main account can’t be removed.")
                        .foregroundStyle(Theme.chromeMuted)
                }.accessibilityIdentifier("claude-account-main")
            }
        }.font(Theme.display(11)).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("claude-accounts-settings")
    }

    private func accountTab(_ title: String, id: UUID?) -> some View {
        Button { selection.accountID = id } label: {
            HStack(spacing: 6) {
                Text(title)
                if id != nil {
                    Text("\(agents(id).count) \(agents(id).count == 1 ? "agent" : "agents")")
                        .font(Theme.display(10, weight: .medium)).foregroundStyle(Theme.claudeAccount)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.claudeAccount.opacity(0.12), in: Capsule())
                }
            }.padding(.horizontal, 12).padding(.vertical, 9)
                .overlay(alignment: .bottom) { if selection.accountID == id { Rectangle().fill(Theme.claudeAccount).frame(height: 2) } }
        }.buttonStyle(.plain).foregroundStyle(selection.accountID == id ? Theme.chromeForeground : Theme.chromeMuted)
            .accessibilityIdentifier(id.map { "claude-account-select-\($0)" } ?? "claude-account-select-main")
    }
}
