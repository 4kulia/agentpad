import SwiftUI
import UniformTypeIdentifiers

struct AvatarOperationBlock: View {
    let editor: ChatAvatarEditor
    var retry: (() -> Void)? = nil
    var choose: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            content.font(Theme.display(12))
        }
    }
    @ViewBuilder private var content: some View {
        switch editor.operation {
        case .idle: EmptyView()
        case .loading, .saving:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text(editor.operation == .loading ? "Reading photo…" : "Saving…")
                    Text("Your current photo stays visible until saving finishes.").foregroundStyle(Theme.chromeMuted)
                }
            }
        case .checking:
            VStack(alignment: .leading, spacing: 8) {
                Label("Checking whether your photo was saved…", systemImage: "arrow.clockwise")
                Text("The response was lost. Check the result before making another change.").foregroundStyle(Theme.chromeMuted)
                Button("Check again") { Task { await editor.retry() } }.disabled(editor.inFlight)
            }
        case .saved: Label("Photo saved", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .unsupported:
            VStack(alignment: .leading, spacing: 6) {
                Label("This server doesn’t support profile photos yet", systemImage: "info.circle")
                Text("Your initials are still shown. Local agent avatars are available on this Mac.").foregroundStyle(Theme.chromeMuted)
            }
        case .failed(let message, let recovery):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                switch recovery {
                case .retry: Button("Retry") { if let retry { retry() } else { Task { await editor.retry() } } }.disabled(!editor.canRetry)
                case .reload: Button("Reload") { Task { await editor.load() } }.disabled(editor.inFlight)
                case .smaller: Button("Use smaller image") { Task { await editor.smaller() } }.disabled(!editor.canRetry)
                case .choose: Button("Choose another…", action: choose)
                case .connect: Button("Connect a team") { SupportTabs.shared.navigation.open(.connection) }
                }
                if let until = editor.retryAt, until > Date() {
                    Text("Retry in \(Int(ceil(until.timeIntervalSinceNow))) seconds").foregroundStyle(Theme.chromeMuted)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct AccountProfileSettings: View {
    var service: ChatService = .shared
    var body: some View {
        Group {
            if service.state == .signedIn, let connection = service.connection, let key = connection.orgKey {
                AccountAvatarForm(key: key, service: service).id(connection.tokenAccount + "|" + key.orgId)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect a team to set your account photo.")
                    Button("Connect a team") { SupportTabs.shared.navigation.open(.connection) }
                }.padding(28)
            }
        }
    }
}

struct AccountAvatarForm: View {
    let key: ChatOrgKey
    let service: ChatService
    @State private var editor: ChatAvatarEditor
    init(key: ChatOrgKey, service: ChatService = .shared) {
        self.key = key; self.service = service
        _editor = State(initialValue: ChatAvatarEditor(reference: .init(key: key, subject: .account(key.accountId)), service: service))
    }
    private var name: String { ChatOrgCurrent.shared.model?.key == key ? ChatOrgCurrent.shared.model?.member(key.accountId)?.name ?? "You" : "You" }
    var body: some View {
        @Bindable var editor = editor
        VStack(alignment: .leading, spacing: 20) {
            Text("Your account on \(key.server.host)").font(Theme.display(12)).foregroundStyle(Theme.chromeMuted)
            VStack(alignment: .leading, spacing: 20) {
                if let source = editor.source {
                    AvatarCropView(source: source, crop: $editor.crop, stableID: key.accountId, name: name, kind: .person,
                                   disabled: editor.blocksEditing, choose: choose)
                } else {
                    HStack(spacing: 20) {
                        ContactAvatar(stableID: key.accountId, name: name, kind: .person, size: 88, remote: editor.reference)
                        VStack(alignment: .leading, spacing: 9) {
                            Text(name).font(Theme.display(18, weight: .semibold))
                            Text("Account photo").font(Theme.display(12)).foregroundStyle(Theme.chromeMuted)
                            HStack {
                                Button(editor.confirmed?.imageId == nil ? "Choose photo…" : "Change…", action: choose)
                                if editor.confirmed?.imageId != nil { Button("Remove") { Task { await editor.remove() } } }
                            }.disabled(editor.blocksEditing || editor.operation == .unsupported)
                            Text("Still JPG or PNG · up to 10 MB").font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
                        }
                    }
                }
                Label("Your photo is visible in organizations you share.", systemImage: "person.2").font(Theme.display(12))
                Text("One photo across your organizations on this server.").font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
                AvatarOperationBlock(editor: editor, choose: choose)
                if editor.source != nil {
                    Divider()
                    HStack {
                        Spacer()
                        Button("Cancel") { editor.cancelCrop() }
                        Button("Save") { Task { await editor.saveCrop() } }.buttonStyle(.borderedProminent)
                    }.disabled(editor.blocksEditing)
                }
            }.padding(24).background(Theme.chromeSelection.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.chromeHairline))
        }.frame(maxWidth: 700, alignment: .leading).padding(28)
            .task(id: service.avatarDisplayContext(key)) { await editor.load() }
            .onDisappear { editor.invalidate() }
    }
    private func choose() {
        guard !editor.blocksEditing, let window = NSApp.keyWindow else { return }
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.jpeg, .png]
        picker.allowsMultipleSelection = false; picker.canChooseDirectories = false
        picker.beginSheetModal(for: window) { response in
            if response == .OK, let url = picker.url { Task { await editor.choose(url) } }
        }
    }
}
