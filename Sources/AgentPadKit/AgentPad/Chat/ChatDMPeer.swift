import Foundation
import GRDB
import Observation
import SwiftUI

/// A local composer addressed to a person. Its draft key is never a server DM ID.
/// The tab owns this observation; sending lives entirely in the outbox.
@MainActor @Observable
final class ChatDMPeerModel: ChatDMComposing {
    let key: ChatOrgKey
    let peer: String
    private weak var service: ChatService?
    private var stopped = false
    @ObservationIgnored private var openingAttachments: Task<Void, Never>?
    private var content = Snapshot()
    private(set) var result: String?
    private(set) var problem: String?
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    private var draftID: String { "peer:\(peer)" }
    private var store: ChatStore? { service?.orgSessions[key]?.store }

    private struct Snapshot: Equatable {
        var member: ChatOrgView.Member?
        var card: ChatDMCard?
        var draft: ChatDMContent.Draft?
        var epoch = -1
        var outgoing: [ChatCommandRecord] = []
        static func read(_ db: Database, peer: String) throws -> Self {
            let member = try ChatOrgView.Member.read(db, account: peer).first
            let card = try ChatDMStore.cardForPeer(db, peer)
            let draft = try ChatDMStore.draft(db, "peer:\(peer)", root: nil).map { ChatDMContent.Draft(text: $0.text, version: $0.version) }
            let commands = try ChatCommandRecord.fetchAll(db, sql: """
                SELECT * FROM outbox WHERE type = 'dm.message.post' AND error IS NOT 'dismissed'
                    AND json_extract(CAST(body_bytes AS TEXT), '$.args.peer_account_id') = ? ORDER BY seq
                """, arguments: [peer])
            var latest: [String: ChatCommandRecord] = [:]
            for command in commands {
                let args = try JSONDecoder().decode(ChatCommandEnvelope.self, from: command.bodyBytes).args
                latest[args["message_id"]?.string ?? command.commandId] = command
            }
            return Self(member: member, card: card, draft: draft,
                        epoch: try Int.fetchOne(db, sql: "SELECT epoch FROM dm_meta") ?? -1,
                        outgoing: latest.values.sorted { $0.seq < $1.seq })
        }
    }
    var readable: Bool {
        guard !stopped, peer != key.accountId, service?.dmAllowed(key) == true, let store,
              content.member != nil || content.card != nil else { return false }
        return (try? store.dmRead { try Int.fetchOne($0, sql: "SELECT epoch FROM dm_meta") }) == content.epoch
    }
    var person: ChatOrgView.Member? { readable ? content.member : nil }
    var writable: Bool { readable && content.member != nil && content.card?.writable != false }
    init(key: ChatOrgKey, peer: String, service: ChatService) {
        self.key = key; self.peer = peer; self.service = service
        guard service.dmAllowed(key), let store else { return }
        observation = ValueObservation.tracking { try Snapshot.read($0, peer: peer) }.removeDuplicates()
            .start(in: store.queue, scheduling: .immediate, onError: { [weak self] _ in
                self?.content = .init()
            }) { [weak self] value in self?.accept(value) }
    }
    var attachmentManager: ChatAttachmentManager? { service?.attachments(key) }
    var attachmentOwner: ChatAttachmentOwner? { content.card.map { .dm($0.dmId) } }
    func attachmentProblem(_ error: Error) { problem = error.localizedDescription }
    func prepareAttachments() async throws -> ChatAttachmentOwner {
        guard readable, let service, attachmentManager?.limits(for: .dm("")) != nil,
              let sync = service.dmSync(key), let token = service.token else { throw ChatAttachmentError.unavailable }
        if let id = content.card?.dmId { return .dm(id) }
        let epoch = sync.epoch
        let api = service.makeAPI(key.server)
        let command = ChatCommandEnvelope(commandId: ChatUUID.v7(), org: key.orgId, type: "dm.open", args: .object(["peer_account_id": .string(peer)]))
        let answer = try await api.call(ChatCommandAnswer.self, "POST", "/v1/commands", token: token, body: command.encoded())
        guard readable, !Task.isCancelled, sync.epoch == epoch, let dm = answer.result["dm_id"]?.string else { throw ChatAttachmentError.unavailable }
        _ = try await sync.refresh(dm)
        guard !Task.isCancelled, service.dmAllowed(key, dm) else { throw ChatAttachmentError.unavailable }
        return .dm(dm)
    }
    func openForAttachments() {
        guard openingAttachments == nil, attachmentManager?.limits(for: .dm("")) != nil else { return }
        openingAttachments = Task { [weak self] in
            do { _ = try await self?.prepareAttachments() }
            catch { if self?.stopped == false { self?.problem = "The conversation could not be opened for files. Try again when connected." } }
            self?.openingAttachments = nil
        }
    }
    var outgoing: [ChatCommandRecord] { readable ? content.outgoing : [] }
    func attribution(_ command: ChatCommandRecord) -> ChatMessageAttribution? {
        let args = ChatService.args(command)
        guard readable, let store, let signature = args["author_session_name"]?.string else { return nil }
        let owner = (try? store.dmRead { try ChatOrgView.Member.read($0, account: key.accountId).first?.name }) ?? "You"
        var message = ChatMessage(dm: .init(messageId: args["message_id"]?.string ?? command.commandId,
            dmId: args["dm_id"]?.string ?? "", authorAccountId: key.accountId, text: args["text"]?.string ?? "",
            mentions: [], revision: 0, seq: 0, createdAt: "", authorSessionName: signature))
        message.localState = .failed
        return ChatMessageAttribution(message, ownerName: owner, ownerHandle: nil)
    }
    private func accept(_ value: Snapshot) {
        content = value
        if value.card?.dmId != result { result = nil }
        guard readable, let card = value.card else { return }
        do { try resolve(card.dmId) }
        catch { problem = error.localizedDescription }
    }
    func draft(root: String?) -> ChatDMContent.Draft? { readable && root == nil ? content.draft : nil }
    @discardableResult func saveDraft(_ text: String, root: String?) -> String? {
        guard writable, root == nil, let store else { return nil }
        do {
            let version = try store.dmWrite { try ChatDMStore.saveDraft($0, draftID, root: nil, text: text) }
            content.draft = .init(text: text, version: version)
            return version
        } catch { problem = "The draft could not be saved on this Mac."; return nil }
    }
    func send(_ text: String, root: String?, members: [(account: String, handle: String)], version: String?) -> Bool {
        guard readable, root == nil, let version, let service else { return false }
        do {
            _ = try service.postDMToPeer(key, peer: peer, text: text,
                mentions: ChatChannelModel.mentions(in: text, members: members), draftVersion: version)
            content.draft = nil; problem = nil
            return true
        } catch { problem = error.localizedDescription; return false }
    }
    func retry(_ command: String) {
        guard readable, let service else { return }
        do { try service.retryDMToPeer(key, peer: peer, command: command); problem = nil }
        catch { problem = error.localizedDescription }
    }
    private func resolve(_ dm: String) throws {
        guard let store else { return }
        try store.dmWrite { db in
            guard let local = try ChatDMStore.draft(db, draftID, root: nil) else { return }
            if !local.text.isEmpty {
                let existing = try ChatDMStore.draft(db, dm, root: nil)
                guard existing == nil || existing?.text.isEmpty == true || existing?.text == local.text else {
                    throw ChatError.storage("This conversation already has another draft. Send or clear this draft before continuing.")
                }
                try db.execute(sql: "INSERT OR REPLACE INTO dm_drafts (dm_id, root, text, version) VALUES (?, '', ?, ?)", arguments: [dm, local.text, local.version])
            }
            try db.execute(sql: "DELETE FROM dm_drafts WHERE dm_id = ?", arguments: [draftID])
        }
        result = dm
    }
    func stop() { stopped = true; openingAttachments?.cancel(); openingAttachments = nil; observation = nil; content = .init(); result = nil; problem = nil }
    func openThread(_ id: String?) {}
    func conversationMessages(root: String?) -> [ChatMessage] { [] }
    func canEdit(_ message: ChatMessage) -> Bool { false }
    func beginEditing(_ message: ChatMessage, root: String?, recovering: Bool) -> Bool { false }
}

extension ChatService {
    func dmPeer(_ key: ChatOrgKey, peer: String) -> ChatDMPeerModel? {
        guard dmAllowed(key), peer != key.accountId, let store = orgSessions[key]?.store,
              (try? store.dmRead { try ChatOrgView.Member.read($0, account: peer).first != nil || ChatDMStore.cardForPeer($0, peer) != nil }) == true else { return nil }
        return ChatDMPeerModel(key: key, peer: peer, service: self)
    }
}

struct ChatDMPeerTab: View {
    @Bindable var state: TabState
    let scope: OrgKey
    let peer: String
    var service: ChatService = .shared
    private var key: ChatOrgKey { .init(server: scope.server, accountId: scope.accountID, orgId: scope.orgID) }
    var body: some View {
        Group {
            if !state.isClosed, let model = state.dmPeerModel, model.readable {
                VStack(spacing: 0) {
                    if let person = model.person {
                        HStack(spacing: 10) {
                            ContactAvatar(stableID: peer, name: person.name, kind: .person, size: 34, remote: .account(peer, key))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(person.name).font(Theme.display(15, weight: .semibold))
                                Label("Only the two of you", systemImage: "lock").font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary)
                            }
                            Spacer()
                        }.padding(16)
                        Divider()
                        Spacer()
                        if model.outgoing.isEmpty {
                            Text("No messages yet").font(Theme.display(14)).foregroundStyle(ChatAppearance.secondary)
                        } else {
                            ScrollView {
                                VStack(alignment: .trailing, spacing: 12) {
                                    ForEach(model.outgoing, id: \.commandId) { command in
                                        if let attribution = model.attribution(command) {
                                            HStack {
                                                Text(verbatim: attribution.title).font(Theme.display(13, weight: .semibold))
                                                ChatBotBadge()
                                            }
                                        }
                                        Text(ChatService.args(command)["text"]?.string ?? "")
                                        if command.state == .pending {
                                            Label("Sending…", systemImage: "clock").foregroundStyle(ChatAppearance.secondary)
                                        } else if command.state == .sent {
                                            Text("Sent").foregroundStyle(ChatAppearance.secondary)
                                        } else if command.isSessionDM {
                                            Text("Delivery unknown. Retry from the originating agent tab.").foregroundStyle(ChatAppearance.secondary)
                                        } else {
                                            Button("Retry sending") { model.retry(command.commandId) }
                                        }
                                    }
                                }.padding(16).frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        Spacer()
                        ChatDMComposer(model: model, root: nil, members: [person], peer: person.name,
                                       isActive: { !state.isClosed && state.route == .directMessageDraft(scope, peer: peer) })
                    }
                }.task(id: service.supports("chat.dm.attachments", key: key)) { model.openForAttachments() }
                .onChange(of: model.result, initial: true) { _, dm in
                    guard let dm, !state.isClosed, service.dmAllowed(key, dm), let owner = SupportTabs.shared.owner(state) else { return }
                    model.stop(); state.dmPeerModel = nil
                    _ = SupportTabs.shared.navigation.router.rekey(owner.session.id, to: .directMessage(ChatDMRef(key, dm: dm)))
                }
            } else {
                Text(service.dmAllowed(key) ? "No access" : "Not connected").foregroundStyle(ChatAppearance.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
            .onChange(of: !state.isClosed && service.dmAllowed(key), initial: true) { _, allowed in
                if allowed, state.dmPeerModel == nil { state.dmPeerModel = service.dmPeer(key, peer: peer) }
                else if !allowed { state.dmPeerModel?.stop(); state.dmPeerModel = nil }
            }
    }
}
