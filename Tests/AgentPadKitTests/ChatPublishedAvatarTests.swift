import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatPublishedAvatarTests: XCTestCase {
    var fixture: AvatarTestFixture!
    var profiles: AgentProfileStore!
    var profile: AgentProfile!
    var agent: TeamPublishedAgent!
    var backend: AvatarTestServer!
    let team = "01900000-0000-7000-8000-000000000006"
    var ref: ChatAvatarReference { .init(key: fixture.key, subject: .agent(agent.id.uuidString.lowercased())) }
    override func setUp() async throws {
        fixture = try AvatarTestFixture(); backend = AvatarTestServer()
        let backend = backend!
        ChatStubProtocol.reset { backend.answer($0, $1) }
        profiles = AgentProfileStore(fileURL: fixture.root.appendingPathComponent("agent-profiles.json"))
        profile = try profiles.add(template: .claudeCode, folder: fixture.root, name: "Builder")
        agent = TeamPublishedAgent(name: "builder", description: "Test", folder: fixture.root.path)
        agent.access = .read
        try profiles.mapPublications([agent])
        try profiles.details.saveAvatar(AvatarTestImage.png(), for: profile.id, expectedRevision: 0)
        fixture.service.avatarProfiles = { [unowned self] in profiles }
        fixture.service.localAgent = { [weak self] id in self?.agent.id.uuidString.lowercased() == id ? self?.agent : nil }
        try fixture.store.apply(.init(cursors: [:], teams: [.init(teamId: team, name: "General", isGeneral: true)], teamMembers: [.init(teamId: team, accountId: fixture.key.accountId)]), confirmsRights: "s")
        try fixture.service.journal?.finish(fixture.key, "g")
    }
    override func tearDown() async throws { await fixture.close(); fixture = nil; profiles = nil; ChatStubProtocol.delay = 0 }
    private func read<T>(_ body: (Database) throws -> T) throws -> T { try fixture.service.journal!.queue.read(body) }
    private func write<T>(_ body: (Database) throws -> T) throws -> T { try fixture.service.journal!.queue.write(body) }
    private func active() throws {
        let row = ChatAssignment(server: fixture.key.server.description, accountId: fixture.key.accountId, orgId: fixture.key.orgId,
            agentId: agent.id.uuidString.lowercased(), state: .active, name: agent.name, description: agent.description, access: "read",
            teamIds: "[\"\(team)\"]", createdAt: Date(), publishedSession: "s")
        try write { try row.insert($0) }
    }
    private func settle() async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !fixture.service.avatarUploads.isEmpty {
            guard ContinuousClock.now < end else { XCTFail("upload did not settle"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func published() -> Bool { !fixture.service.avatarNotPublished(profile.id, ref: ref, profiles: profiles) }
    func testInitialPublicationHasNoAvatarAndOnlyAcceptedExplicitPublishStartsSeparatePUT() async throws {
        try fixture.service.publish([agent], teams: [team], key: fixture.key)
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
        let journal = try XCTUnwrap(fixture.service.journal)
        let command = try read { try XCTUnwrap(ChatCommandRecord.fetchOne($0, sql: "SELECT * FROM run_commands WHERE type = 'agent.publish'")) }
        let envelope = try JSONDecoder().decode(ChatCommandEnvelope.self, from: command.bodyBytes)
        XCTAssertNil(envelope.args["avatar"]); XCTAssertNil(envelope.args["avatarRevision"])
        XCTAssertNil(envelope.args["profile_id"])
        let requested = try journal.assignment(fixture.key, agentId: agent.id.uuidString.lowercased())
        XCTAssertEqual(ChatPublishRequest.decode(requested?.requested)?.avatarRevision, 1)
        try write { try $0.execute(sql: "UPDATE run_commands SET state = 'sent' WHERE command_id = ?", arguments: [command.commandId]) }
        fixture.service.settlePublications(fixture.key)
        try await settle()
        XCTAssertTrue(published())
        XCTAssertEqual(ChatStubProtocol.seen.filter { $0.request.httpMethod == "PUT" }.count, 1)
        XCTAssertTrue(ChatStubProtocol.seen.allSatisfy { $0.request.url?.path.contains("/agents/\(agent.id.uuidString.lowercased())/avatar") == true })
        XCTAssertEqual(try journal.assignment(fixture.key, agentId: agent.id.uuidString.lowercased())?.access, "read")
        let restarted = AgentProfileDetailsStore(fileURL: profiles.details.fileURL)
        XCTAssertEqual(restarted.publishedAvatar(ref, profile: profile.id)?.localRevision, 1)
    }
    func testLocalChangeFailureKeepsPublicationAndRetryAndRemovalHaveIndependentRevisions() async throws {
        try active(); backend.change { $0.rejection = (503, "overloaded", nil) }
        await fixture.service.uploadProfileAvatar(profile.id, ref: ref, profiles: profiles, revision: 1)
        XCTAssertFalse(published())
        XCTAssertEqual(try fixture.service.journal?.assignment(fixture.key, agentId: ref.subject.id)?.state, .active)
        backend.change { $0.rejection = nil }
        let editor = try XCTUnwrap(fixture.service.avatarEdits[ref])
        await editor.retry(); XCTAssertTrue(published())
        let accepted = profiles.details.publishedAvatar(ref, profile: profile.id)
        try profiles.details.saveAvatar(nil, for: profile.id, expectedRevision: 1)
        XCTAssertFalse(published())
        await fixture.service.uploadProfileAvatar(profile.id, ref: ref, profiles: profiles, revision: 2)
        XCTAssertTrue(published()); XCTAssertNil(profiles.details.publishedAvatar(ref, profile: profile.id)?.avatar.imageId)
        XCTAssertEqual(profiles.details.publishedAvatar(ref, profile: profile.id)?.avatar.revision, (accepted?.avatar.revision ?? 0) + 1)
        XCTAssertEqual(try fixture.service.journal?.assignment(fixture.key, agentId: ref.subject.id)?.access, "read")
        XCTAssertEqual(ChatStubProtocol.seen.last?.request.httpMethod, "DELETE")
    }
    func testReannouncementOmitsAvatarAndNeverUploadsUnpublishedLocalChange() async throws {
        try active()
        let journal = try XCTUnwrap(fixture.service.journal)
        try write { try $0.execute(sql: "UPDATE assignments SET published_session = 'old'") }
        fixture.service.announceAfterNewSession(fixture.key)
        let commands = try read { try ChatCommandRecord.fetchAll($0, sql: "SELECT * FROM run_commands") }
        XCTAssertEqual(commands.count, 1)
        for command in commands {
            let envelope = try JSONDecoder().decode(ChatCommandEnvelope.self, from: command.bodyBytes)
            XCTAssertNil(envelope.args["avatar"])
        }
        try write { try $0.execute(sql: "UPDATE run_commands SET state = 'sent'") }
        fixture.service.settlePublications(fixture.key); try await settle()
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty); XCTAssertFalse(published())
    }
    func testWrongAccountOrgForeignAgentOffAndAbsentCapabilityNeverUpload() async throws {
        try active()
        var wrong = fixture.key
        wrong = .init(server: wrong.server, accountId: team, orgId: wrong.orgId)
        await fixture.service.uploadProfileAvatar(profile.id, ref: .init(key: wrong, subject: ref.subject), profiles: profiles, revision: 1)
        wrong = .init(server: fixture.key.server, accountId: fixture.key.accountId, orgId: team)
        await fixture.service.uploadProfileAvatar(profile.id, ref: .init(key: wrong, subject: ref.subject), profiles: profiles, revision: 1)
        await fixture.service.uploadProfileAvatar(profile.id, ref: .init(key: fixture.key, subject: .agent(team)), profiles: profiles, revision: 1)
        fixture.service.serverCapabilities[fixture.key.server] = []
        await fixture.service.uploadProfileAvatar(profile.id, ref: ref, profiles: profiles, revision: 1)
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty); XCTAssertFalse(published())
        XCTAssertEqual(fixture.service.avatarEdits[ref]?.operation, .unsupported)
        let reference = ref
        await fixture.service.disconnect()
        await fixture.service.uploadProfileAvatar(profile.id, ref: reference, profiles: profiles, revision: 1)
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
    }
    func testOldPublishIntentAndLateWritesNeverConfirmNewerLocalRevision() async throws {
        try active()
        try profiles.details.saveAvatar(nil, for: profile.id, expectedRevision: 1)
        await fixture.service.uploadProfileAvatar(profile.id, ref: ref, profiles: profiles, revision: 1)
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
        // A local edit during a write leaves the new local version pending.
        ChatStubProtocol.delay = 0.04
        let work = Task { await fixture.service.uploadProfileAvatar(profile.id, ref: ref, profiles: profiles, revision: 2) }
        let end = ContinuousClock.now + .seconds(2)
        while ChatStubProtocol.seen.filter({ $0.request.httpMethod == "DELETE" }).isEmpty {
            guard ContinuousClock.now < end else { return XCTFail("No DELETE") }
            try await Task.sleep(for: .milliseconds(5))
        }
        try profiles.details.saveAvatar(AvatarTestImage.png(), for: profile.id, expectedRevision: 2)
        await work.value
        XCTAssertFalse(published()); XCTAssertEqual(profiles.details.publishedAvatar(ref, profile: profile.id)?.localRevision, 2)
        let writes = ChatStubProtocol.seen.filter { $0.request.httpMethod != "GET" }
        XCTAssertEqual(writes.count, 1)
    }
    func testCapabilityRestorationMakesUnsupportedPublicationRetryableWithoutLocalEdit() async throws {
        try active()
        fixture.service.serverCapabilities[fixture.key.server] = []
        let local = profiles.details.avatar(profile.id)
        let url = try XCTUnwrap(profiles.details.avatarURL(profile.id))
        let bytes = try Data(contentsOf: url)
        await fixture.service.uploadProfileAvatar(profile.id, ref: ref, profiles: profiles, revision: local.revision)
        let editor = try XCTUnwrap(fixture.service.avatarEdits[ref])
        XCTAssertEqual(editor.operation, .unsupported)
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)

        // Same server generation, upgraded in place; the user has not edited again.
        fixture.service.serverCapabilities[fixture.key.server] = ["chat.avatars"]
        XCTAssertTrue(editor.canRetry)
        if case .failed(_, .retry) = editor.operation {} else { XCTFail("The operation block must show Retry") }
        XCTAssertFalse(published())
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty, "Restoring support must wait for explicit Retry")
        XCTAssertEqual(profiles.details.avatar(profile.id).revision, local.revision)
        XCTAssertEqual(try Data(contentsOf: url), bytes)

        fixture.service.beginProfileAvatar(profile.id, ref: ref, profiles: profiles, revision: local.revision)
        try await settle()
        XCTAssertTrue(published())
        XCTAssertEqual(editor.operation, .saved)
        XCTAssertEqual(profiles.details.avatar(profile.id).revision, local.revision)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testLostReplyIsCheckedAndUnpublishDropsLateReceipt() async throws {
        try active(); backend.change { $0.losses = 2 }
        await fixture.service.uploadProfileAvatar(profile.id, ref: ref, profiles: profiles, revision: 1)
        let editor = try XCTUnwrap(fixture.service.avatarEdits[ref])
        XCTAssertEqual(editor.operation, .checking); XCTAssertFalse(published())
        await editor.retry(); XCTAssertTrue(published())
        try profiles.details.saveAvatar(nil, for: profile.id, expectedRevision: 1)
        ChatStubProtocol.delay = 0.04
        let work = Task { await fixture.service.uploadProfileAvatar(profile.id, ref: ref, profiles: profiles, revision: 2) }
        let end = ContinuousClock.now + .seconds(2)
        while fixture.service.avatarEdits[ref]?.inFlight != true {
            guard ContinuousClock.now < end else { return XCTFail("No avatar operation started") }
            try await Task.sleep(for: .milliseconds(5))
        }
        try write { try $0.execute(sql: "UPDATE assignments SET state = 'removing'") }
        fixture.service.invalidateAvatars()
        await work.value
        XCTAssertFalse(published()); XCTAssertEqual(profiles.details.publishedAvatar(ref, profile: profile.id)?.localRevision, 1)
    }
    func testLocalEditorSaveUploadsOnlyForAlreadyPublishedAgent() async throws {
        let local = AgentProfileEditor(profile: profile, profiles: profiles, avatarService: fixture.service)
        local.source = try AvatarTestImage.make()
        await local.saveCrop(); try await settle()
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty, "A local profile never uploads on its own")
        try active()
        await local.remove(); try await settle()
        XCTAssertTrue(published())
        XCTAssertEqual(profiles.details.publishedAvatar(ref, profile: profile.id)?.localRevision, 3)
        XCTAssertEqual(ChatStubProtocol.seen.last?.request.httpMethod, "DELETE")
    }
    func testRepublishedAgentChecksTombstoneBeforeRestoringSameLocalImage() async throws {
        try active()
        await fixture.service.uploadProfileAvatar(profile.id, ref: ref, profiles: profiles, revision: 1)
        XCTAssertTrue(published())
        fixture.service.invalidateAvatars()
        backend.change { $0.revision += 1; $0.image = nil; $0.bytes = nil }
        await fixture.service.uploadProfileAvatar(profile.id, ref: ref, profiles: profiles, revision: 1)
        XCTAssertTrue(published())
        backend.change { XCTAssertEqual($0.writes, 2) }
        XCTAssertEqual(profiles.details.publishedAvatar(ref, profile: profile.id)?.avatar.revision, 3)
    }

    func testPublishedAvatarComparisonRendersWithoutOCR() async throws {
        try active()
        let previous = AgentPadSettingsModel.testModel
        defer { AgentPadSettingsModel.testModel = previous }
        for dark in [false, true] {
            AgentPadSettingsModel.testModel = AgentPadSettingsModel(read: { ["appearance": ["mode": dark ? "dark" : "light"]] }, write: { _ in }, appliesRuntimeEffects: false)
            let host = NSHostingView(rootView: VStack { PublishedProfileAvatars(profile: profile.id, profiles: profiles, service: fixture.service) }
                .padding(24).frame(width: 680, height: 360).foregroundStyle(Theme.chromeForeground)
                .background(Theme.chromeBackground).environment(\.colorScheme, Theme.chromeColorScheme))
            host.frame = NSRect(x: 0, y: 0, width: 680, height: 360); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let root = ProcessInfo.processInfo.environment["AGENTPAD_TEST_ARTIFACTS"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: root).appendingPathComponent("published-avatar-\(dark ? "dark" : "light").png"))
            }
        }
    }

    func testChoosingANewLocalImageAfterRejectionReplacesTheFailedAvatarAttempt() async throws {
        try active(); backend.change { $0.rejection = (415, "unsupported_media_type", nil) }
        await fixture.service.uploadProfileAvatar(profile.id, ref: ref, profiles: profiles, revision: 1)
        guard case .failed(_, .choose) = fixture.service.avatarEdits[ref]?.operation else { return XCTFail("Choose expected") }
        backend.change { $0.rejection = nil }
        let local = AgentProfileEditor(profile: profile, profiles: profiles, avatarService: fixture.service)
        local.source = try AvatarTestImage.make(noise: true)
        await local.saveCrop(); try await settle()
        XCTAssertTrue(published())
        XCTAssertEqual(profiles.details.publishedAvatar(ref, profile: profile.id)?.localRevision, 2)
        XCTAssertEqual(fixture.service.avatarEdits[ref]?.operation, .saved)
    }

}
