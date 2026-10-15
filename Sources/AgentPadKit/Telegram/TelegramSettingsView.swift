import AgentPadTelegram
import SwiftUI

struct TelegramSettingsView: View {
    @Bindable var model: TelegramSettingsViewModel
    @State private var confirmLocalRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "paperplane.fill").font(.system(size: 23)).foregroundStyle(.white)
                    .frame(width: 46, height: 46).background(.blue, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(status).font(Theme.display(14, weight: .semibold))
                    Text("Settings · This Mac").font(Theme.display(11)).foregroundStyle(.secondary)
                }
                Spacer()
                if case .connected = model.snapshot.state {
                    Button("Disconnect this Mac") { Task { await model.disconnect() } }
                        .accessibilityIdentifier("telegram-disconnect")
                }
            }
            HStack(spacing: 0) {
                Text("Local").padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Theme.chromeSelection, in: RoundedRectangle(cornerRadius: 6))
                Button("Server · Coming later") {}.disabled(true).buttonStyle(.borderless).padding(.horizontal, 16)
            }.font(Theme.display(12))

            authContent
            SidebarFolderSettings(compact: true)
            if TelegramService.chats.connected {
                Toggle("Direct messages in Attention", isOn: Binding(
                    get: { TelegramService.chats.snapshot.attention.directEnabled },
                    set: { enabled in Task { await TelegramService.chats.provider?.setDirectAttention(enabled) } }))
                    .font(Theme.display(12))
                Text("Follows your Telegram notification settings. Find any chat with ⌘P.")
                    .font(Theme.display(11)).foregroundStyle(.secondary)
            }
            if let failure = model.snapshot.failure {
                Text(failure.message).font(Theme.display(12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("telegram-error")
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("Privacy & local storage", systemImage: "lock").font(Theme.display(13, weight: .semibold))
                Text(TelegramBuild.privacyText).font(Theme.display(12))
                    .fixedSize(horizontal: false, vertical: true)
                Text("AgentPad uses the Telegram API and is an independent, unofficial Telegram client.")
                    .font(Theme.display(11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28).padding(.bottom, 28)
        .frame(maxWidth: 680, alignment: .leading)
        .disabled(model.isWorking)
        .task { model.start() }
        .alert("Remove Telegram data only from this Mac?", isPresented: $confirmLocalRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove local data", role: .destructive) { Task { await model.removeLocalData() } }
        } message: {
            Text("This does not log out the session on Telegram. Revoke AgentPad in Telegram → Settings → Devices. The local session, cache, and settings will be removed from this Mac.")
        }
        .accessibilityIdentifier("telegram-settings")
    }

    private var status: String {
        switch model.snapshot.state {
        case .connected:
            switch model.snapshot.network {
            case .ready: "Telegram connected"
            case .updating: "Telegram updating"
            case .connecting: "Reconnecting to Telegram"
            case .waiting: "Telegram offline"
            }
        case .disconnected, .disabled: "Telegram not connected"
        case .cleanupPending, .loggingOut: "Disconnecting Telegram"
        case .reauthenticationRequired: "Sign in to Telegram again"
        case .blocked: "Telegram needs your attention"
        default: "Connect Telegram"
        }
    }

    @ViewBuilder private var authContent: some View {
        switch model.snapshot.state {
        case .disconnected:
            Button("Connect Telegram…") { Task { await model.connect() } }.buttonStyle(.borderedProminent)
                .accessibilityIdentifier("telegram-connect")
        case .disabled: EmptyView()
        case .starting, .requestingQR, .verifyingAccount:
            HStack { ProgressView().controlSize(.small); Text("Connecting to Telegram…") }
            cancel
            if model.snapshot.state == .requestingQR {
                Button("Use phone number instead") { Task { await model.usePhone() } }
            }
        case .qr:
            VStack(alignment: .leading, spacing: 14) {
                Text("Scan with Telegram on your phone").font(Theme.display(15, weight: .semibold))
                Group {
                    if let image = model.qrImage {
                        Image(nsImage: image).interpolation(.none).resizable().aspectRatio(contentMode: .fit)
                            .padding(16).background(.white)
                    } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.frame(width: 208, height: 208)
                    .accessibilityLabel("Telegram sign-in QR code").accessibilityIdentifier("telegram-qr")
                Text("Open Telegram → Settings → Devices → Link Desktop Device.")
                    .font(Theme.display(12)).foregroundStyle(.secondary)
                HStack {
                    Button("Use phone number instead") { Task { await model.usePhone() } }
                    cancel
                }
            }
        case .password(let hint):
            VStack(alignment: .leading, spacing: 12) {
                Text("Two-step verification").font(Theme.display(15, weight: .semibold))
                Text("Enter your Telegram password.").font(Theme.display(12)).foregroundStyle(.secondary)
                if !hint.isEmpty { Text("Hint: \(hint)").font(Theme.display(12)).foregroundStyle(.secondary) }
                SecureField("Password", text: $model.input).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.submit() } }.disabled(model.snapshot.isSubmitting)
                    .accessibilityIdentifier("telegram-password")
                formActions
            }.frame(maxWidth: 380)
        case .phoneNumber:
            form("Phone number", detail: "Include the country code. Telegram will choose how to deliver the code.")
            Button("Use QR code instead") { Task { await model.useQR() } }.disabled(model.snapshot.isSubmitting)
        case .code(let info):
            form("Confirmation code", detail: info.delivery)
            if let date = info.resendAvailableAt {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Button(timeline.date >= date ? "Resend code" : "Resend in \(max(1, Int(date.timeIntervalSince(timeline.date).rounded(.up))))s") {
                        Task { await model.resend() }
                    }.disabled(timeline.date < date || model.snapshot.isSubmitting)
                }
            }
        case .emailAddress: form("Email address", detail: "Telegram requires an email address for this sign-in.")
        case .emailCode(let pattern):
            form("Email confirmation code", detail: pattern.isEmpty ? "Enter the code from Telegram's email." : "Enter the code sent to \(pattern).")
            Button("Resend code") { Task { await model.resend() } }.disabled(model.snapshot.isSubmitting)
        case .connected(let account):
            VStack(alignment: .leading, spacing: 8) {
                Text("Telegram, connected.").font(Theme.display(15, weight: .semibold))
                Text(account.displayName).font(Theme.display(13))
                if let username = account.username { Text("@" + username).font(Theme.display(12)).foregroundStyle(.secondary) }
                Text("Disconnect this Mac logs out this Telegram session and removes its local cache and settings.")
                    .font(Theme.display(11)).foregroundStyle(.secondary)
            }.accessibilityIdentifier("telegram-connected-account")
        case .loggingOut, .closing:
            HStack { ProgressView().controlSize(.small); Text("Closing the Telegram connection…") }
            if model.snapshot.failure != nil { localRemoval }
        case .cleanupPending:
            HStack {
                Button("Retry logout") { Task { await model.retry() } }
                localRemoval
            }
        case .reauthenticationRequired:
            Button("Sign in again") { Task { await model.retry() } }.buttonStyle(.borderedProminent)
            localRemoval
        case .blocked:
            Text(TelegramFolderRollback.note).font(Theme.display(11)).foregroundStyle(.secondary)
            HStack {
                Button("Retry connection") { Task { await model.retry() } }
                localRemoval
            }
        case .unsupported:
            Link("Open official Telegram", destination: URL(string: "https://telegram.org/apps")!)
            cancel
        }
    }
    private func form(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Theme.display(15, weight: .semibold))
            Text(detail).font(Theme.display(12)).foregroundStyle(.secondary)
            TextField(title, text: $model.input).textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.submit() } }.disabled(model.snapshot.isSubmitting)
                .accessibilityIdentifier("telegram-auth-input")
            formActions
        }.frame(maxWidth: 380)
    }
    private var formActions: some View {
        HStack {
            Button(model.snapshot.isSubmitting ? "Waiting for Telegram…" : "Continue") { Task { await model.submit() } }
                .buttonStyle(.borderedProminent).disabled(model.input.isEmpty || model.snapshot.isSubmitting)
            cancel
        }
    }
    private var cancel: some View { Button("Cancel") { Task { await model.disconnect() } } }
    private var localRemoval: some View {
        Button("Remove data only from this Mac…", role: .destructive) { confirmLocalRemoval = true }
    }
}
