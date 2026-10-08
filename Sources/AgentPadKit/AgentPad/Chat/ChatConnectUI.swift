import AppKit
import SwiftUI

/// The steps of Team → Connect to a Server… (docs/agentpad/CHAT-PLAN.md C5),
/// kept in the tab state, independently of SwiftUI mounts.
@MainActor
@Observable
final class ChatConnectModel {
    /// After a sign-in: Claude tabs already open have no team tools.
    static let restartClaudeHint = "Claude Code sessions already open get the Team tools once you start claude again in their tabs."

    enum Step: Equatable {
        /// Server address and email.
        case address
        /// The code from the letter.
        case code
        /// Several organizations: the user picks one.
        case chooseOrg([ChatOrgMembership])
        /// The member's name is still its handle: asked once.
        case name(ChatOrgKey)
        /// Signed in but in no organization: nothing was kept.
        case noOrganization
        case done
    }

    static let defaultServer = "https://agentpad.rabbitshat.ai"
    static let resendAfter: TimeInterval = 30

    var serverText = ChatConnectModel.defaultServer
    var email = ""
    var code = ""
    var displayName = ""
    var deviceName = String((Host.current().localizedName ?? "Mac").prefix(64))
    private(set) var step: Step = .address
    private(set) var error: String?
    private(set) var busy = false
    private(set) var codeSentAt: Date?

    private let service: ChatService
    /// Nothing of team work runs here (no call, no run not confirmed gone):
    /// only then may this Mac move to a server. Replaced in tests.
    var teamWorkIdle: @MainActor () -> Bool = { TeamService.shared.canMoveToServer }
    /// The tab says a call still runs here and offers Team activity.
    private(set) var teamWorkInTheWay = false
    /// `TeamMode.switchToServer`, with the server service started.
    private let switchToServer: @MainActor () async throws -> Void
    var now: () -> Date = Date.init
    private var server: ChatServerAddress?
    private var answer: ChatSignIn?
    private var representedConnection: ChatConnection?
    private(set) var isClosed = false

    init(service: ChatService = .shared, switchToServer: @escaping @MainActor () async throws -> Void = ChatConnectModel.switchApp) {
        self.service = service
        self.switchToServer = switchToServer
        representedConnection = service.connection
        if service.connection != nil, service.state == .signedIn { step = .done }
    }

    var connectionChanged: Bool {
        !busy && (representedConnection != service.connection || (step == .done && service.state != .signedIn))
    }

    /// The app's step after a sign-in: `TeamMode.switchToServer`, whose step
    /// 5 starts serving the new session — or, already in server mode, the
    /// service starts again with it. When that fails, the sign-in is not kept
    /// (review C-18).
    static func switchApp() async throws {
        if TeamService.shared.mode == .server {
            try await ChatService.shared.keepSignIn()
            try await ChatService.shared.start(mode: .server)
            TeamService.shared.updateTeamTools()
        } else {
            // The record is written once the move began, never before.
            try await TeamMode.switchToServer {
                try await ChatService.shared.keepSignIn()
                try await ChatService.shared.start(mode: $0)
            }
        }
    }

    var canResend: Bool {
        guard step == .code, let codeSentAt else { return false }
        return now().timeIntervalSince(codeSentAt) >= Self.resendAfter
    }

    // MARK: Steps

    /// Checks the server and asks it to mail a code.
    func sendCode() async {
        guard !blockedByTeamWork() else { return }
        await run {
            let server = try ChatServerAddress(parsing: self.serverText)
            let email = self.email.trimmingCharacters(in: .whitespaces)
            guard email.contains("@") else { throw Problem.text("Enter your email address.") }
            // Everything a connection needs, before anything is kept (review C-20).
            _ = try await self.service.makeAPI(server).serverInfo(requiring: ChatAPI.requiredCapabilities)
            guard !self.isClosed else { return }
            try await self.service.requestCode(server: server, email: email)
            guard !self.isClosed else { return }
            self.server = server
            self.email = email
            self.codeSentAt = self.now()
            self.code = ""
            self.step = .code
        }
    }

    func resendCode() async {
        guard canResend, let server else { return }
        await run {
            try await self.service.requestCode(server: server, email: self.email)
            guard !self.isClosed else { return }
            self.code = ""
            self.codeSentAt = self.now()
        }
    }

    /// A wrong code and a lost answer both keep the tab on this step.
    func submitCode() async {
        guard step == .code, let server else { return }
        await run {
            let code = self.code.trimmingCharacters(in: .whitespaces)
            let answer: ChatSignIn
            do {
                answer = try await self.service.authenticate(server: server, email: self.email, code: code, deviceName: self.deviceName)
            } catch ChatAPIError.network {
                // The code may be used up already: only a new one helps.
                throw Problem.text("The answer to the sign-in was lost. Ask for a new code and try again.")
            }
            self.code = ""
            guard !self.isClosed else {
                await self.service.discard(answer, server: server)
                return
            }
            self.answer = answer
            switch answer.orgs.count {
            case 0:
                await self.service.discard(answer, server: server)
                self.answer = nil
                if !self.isClosed { self.step = .noOrganization }
            case 1:
                try await self.finish(answer.orgs[0])
            default:
                self.step = .chooseOrg(answer.orgs)
            }
        }
    }

    func choose(_ orgId: String) async {
        guard let org = answer?.orgs.first(where: { $0.orgId == orgId }) else { return }
        await run { try await self.finish(org) }
    }

    private func finish(_ org: ChatOrgMembership) async throws {
        guard let server, let answer else { return }
        let connection: ChatConnection
        do {
            connection = try await service.completeSignIn(answer, server: server, deviceName: deviceName, orgId: org.orgId,
                                                          stillValid: { !self.isClosed })
        } catch {
            if isClosed {
                self.answer = nil
                await service.discard(answer, server: server)
            } else {
                // A Keychain failure has not committed the sign-in. Keep the
                // temporary authorization for Retry, Back or tab cleanup.
                step = .chooseOrg(answer.orgs)
            }
            throw error
        }
        self.answer = nil
        representedConnection = connection
        guard !isClosed else {
            await service.discardSignIn(expecting: connection)
            return
        }
        do {
            try await switchToServer()
        } catch TeamError.teamWorkOn {
            // A call began meanwhile; the move was refused before it began:
            // the sign-in goes, no record was written.
            await service.discardSignIn()
            step = .address
            teamWorkInTheWay = true
            throw TeamError.teamWorkOn
        } catch {
            // Team work did not move to the server: the sign-in is not kept.
            await service.disconnect()
            step = .address
            throw error
        }
        guard !isClosed else { return }
        if org.name == org.handle, let key = connection.orgKey {
            displayName = ""
            step = .name(key)
        } else {
            step = .done
        }
    }

    /// Sends `member.set_name` through the send queue.
    func saveName() async {
        guard case .name(let key) = step else { return }
        await run {
            let name = self.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...64).contains(name.count) else { throw Problem.text("A name has 1 to 64 characters.") }
            try self.service.enqueue(key, type: "member.set_name", args: .object(["name": .string(name)]))
            self.step = .done
        }
    }

    func skipName() { if case .name = step { step = .done } }

    func back() {
        guard !busy, !isClosed else { return }
        discardPendingSignIn()
        step = .address
        error = nil
        code = ""
        codeSentAt = nil
    }

    /// Closing forgets all input synchronously. A late authentication answer
    /// is revoked by submitCode; a chosen, committed sign-in belongs to the core.
    func close() {
        isClosed = true
        code = ""
        email = ""
        displayName = ""
        error = nil
        codeSentAt = nil
        step = .address
        // finish owns the answer while it is committing, including cleanup.
        if !busy { discardPendingSignIn() } else { answer = nil }
    }

    private func discardPendingSignIn() {
        if let answer, let server {
            Task { [service] in await service.discard(answer, server: server) }
        }
        answer = nil
    }

    // MARK: Errors

    private enum Problem: Error { case text(String) }

    /// True (with the tab saying so) while something of team work runs.
    private func blockedByTeamWork() -> Bool {
        teamWorkInTheWay = !teamWorkIdle()
        if teamWorkInTheWay { error = TeamError.teamWorkOn.localizedDescription }
        return teamWorkInTheWay
    }

    private func run(_ work: @MainActor () async throws -> Void) async {
        guard !busy, !isClosed else { return }
        busy = true
        error = nil
        defer { busy = false }
        do { try await work() } catch { if !isClosed { self.error = Self.text(for: error) } }
    }

    static func text(for error: Error) -> String {
        switch error {
        case Problem.text(let text): return text
        case let problem as ChatServerAddress.Problem: return problem.localizedDescription
        case ChatAPIError.network: return "The server cannot be reached. Check the address and the network."
        case ChatAPIError.unsuitableServer: return "This server's version does not fit this AgentPad."
        case ChatAPIError.redirect: return "The server answered with a redirect; check the address."
        case ChatAPIError.server(_, "invalid_code", _): return "The code is wrong or has expired. Ask for a new one."
        case ChatAPIError.server(_, "invalid_request", _): return "The server did not accept this address or name."
        default: return error.localizedDescription
        }
    }
}

struct ChatConnectView: View {
    @Bindable var model: ChatConnectModel
    let onClose: () -> Void
    let onDisconnect: () -> Void
    @State private var tick = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            if let error = model.error {
                Text(error).font(Theme.display(11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if model.teamWorkInTheWay {
                Button("Show Team…") { TeamUI.showTeam() }.disabled(model.busy)
            }
        }
        .padding(18)
        .frame(maxWidth: 520, alignment: .leading)
        .attentionPlace([.connect])
        .disabled(model.busy)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { tick = $0 }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .address:
            Text("Connect to an AgentPad server").font(Theme.display(14, weight: .semibold))
            TextField("Server address", text: $model.serverText)
            TextField("Email", text: $model.email)
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                Button("Send Code") { Task { await model.sendCode() } }.keyboardShortcut(.defaultAction)
            }
        case .code:
            Text("Enter the code from the letter").font(Theme.display(14, weight: .semibold))
            Text("Sent to \(model.email). The code is valid for 10 minutes.")
                .font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
            TextField("8-digit code", text: $model.code)
            HStack {
                Button("Back") { model.back() }
                let _ = tick
                Button("Send the Code Again") { Task { await model.resendCode() } }.disabled(!model.canResend)
                Spacer()
                Button("Sign In") { Task { await model.submitCode() } }.keyboardShortcut(.defaultAction)
            }
        case .chooseOrg(let orgs):
            Text("Choose an organization").font(Theme.display(14, weight: .semibold))
            Text("To open another one later, disconnect and connect again.")
                .font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
            ForEach(orgs, id: \.orgId) { org in
                Button("\(org.orgName) — \(org.role)") { Task { await model.choose(org.orgId) } }
            }
            Button("Back") { model.back() }
        case .name:
            Text("Your name in the organization").font(Theme.display(14, weight: .semibold))
            Text("Colleagues see it next to your messages and agents.")
                .font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
            TextField("Name", text: $model.displayName)
            HStack {
                Spacer()
                Button("Later") { model.skipName() }
                Button("Save") { Task { await model.saveName() } }.keyboardShortcut(.defaultAction)
            }
        case .noOrganization:
            Text("Your account is not a member of any organization on this server.")
                .font(Theme.display(13)).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Close", action: onClose).keyboardShortcut(.defaultAction) }
        case .done:
            Text("Connected").font(Theme.display(14, weight: .semibold))
            // A Claude session reads the team tools once, at its start (DESIGN-D6 §7.2).
            Text(ChatConnectModel.restartClaudeHint)
                .font(Theme.display(12)).foregroundStyle(Theme.chromeMuted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Disconnect…", action: onDisconnect)
                Spacer()
                Button("Close", action: onClose)
            }
        }
    }
}
