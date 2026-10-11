import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor
final class PublicationPrivacyTests: XCTestCase {
    private var root: URL!
    private var scope: TeamServiceTestScope!
    private var source: ClosedSessionNameFixture!
    private var f: ChatChannelExecutionTests.Fixture!
    private var boxes: [ChatOutbox] = []
    private let title = "PRIVATE-TITLE-MARKER " + String(repeating: "confidential session details ", count: 6)

    override func setUp() async throws {
        scope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("publication-privacy-\(UUID())")
        let metadata = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "custom-title", "customTitle": title]), as: UTF8.self)
        source = try ClosedSessionNameFixture(root: root.appendingPathComponent("source"), metadata: metadata)
        f = try await ChatChannelExecutionTests.Fixture(root: root.appendingPathComponent("chat"))
        f.service.claudeProjectsRoot = source.store.claudeProjectsRoot
        f.agent.name = TeamPublishedAgent.suggestedName(title)
        f.agent.description = title
        f.agent.folder = source.record.cwd.path
        f.agent.sessionId = source.record.conversationId
        f.agent.sessionTitle = TeamText.sanitizedName(title)
        try f.assign()
        ChatStubProtocol.reset()
    }

    override func tearDown() async throws {
        boxes.forEach { $0.hold() }; boxes = []
        await f?.service.disconnect()
        source?.store.terminate(); f = nil; source = nil
        ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: root)
        scope.close(); scope = nil
    }

    private func commands() throws -> [ChatCommandRecord] {
        try f.journal.commands(for: f.key).filter { $0.type == ChatService.publishType }
    }

    private func assignment() throws -> ChatAssignment {
        try XCTUnwrap(f.journal.assignment(f.key, agentId: f.agent.id.uuidString.lowercased()))
    }

    private func assertStoredText(_ record: ChatCommandRecord,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let envelope = try JSONDecoder().decode(ChatCommandEnvelope.self, from: record.bodyBytes)
        XCTAssertEqual(envelope.args["name"]?.string, f.agent.name, file: file, line: line)
        XCTAssertEqual(envelope.args["description"]?.string, f.agent.description, file: file, line: line)
        XCTAssertNil(envelope.args["nameWasEdited"], file: file, line: line)
        XCTAssertNil(envelope.args["descriptionWasEdited"], file: file, line: line)
    }

    private func storedCommand(state: ChatCommandRecord.State = .pending) throws -> ChatCommandRecord {
        let asked = ChatPublishRequest(agent: f.agent, teams: f.service.myTeams(f.key).map(\.teamId))
        let now = Date(), id = ChatUUID.v7(), agent = f.agent.id.uuidString.lowercased()
        let bytes = try ChatCommandEnvelope(commandId: id, org: f.key.orgId, type: ChatService.publishType,
            args: .object(["agent_id": .string(agent), "name": .string(asked.name), "description": .string(asked.description),
                "access": .string(asked.access), "team_ids": .array(asked.teamIds.map(ChatJSON.string))])).encoded() + Data("\n  ".utf8)
        var row = try assignment()
        row.requested = asked.json; row.requestedAt = now
        try f.journal.save(row)
        return try f.journal.enqueue(.init(commandId: id, sessionId: "s-anna", type: ChatService.publishType,
            bodyBytes: bytes, orderKey: "exec:agent:\(agent)", dependsOn: nil, createdAt: now, state: state), key: f.key)
    }

    private func sender(reopened: Bool = false) throws -> ChatOutbox {
        let journal = reopened ? try ChatJournal.open(files: f.service.files) : f.journal
        let box = ChatOutbox(queues: [f.store.outbox, journal.runCommands(f.key)],
            api: f.service.makeAPI(f.key.server), token: "test-only", sessionId: "s-anna", held: true)
        f.service.configureCommandCapabilities(box, key: f.key)
        box.retryDelay = { _ in 0.01 }
        boxes.append(box)
        return box
    }

    private func waitUntil(_ condition: () throws -> Bool) async throws {
        for _ in 0..<500 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the test outbox")
    }

    func testAutomaticRepublishKeepsConfirmedTextAcrossSessionRename() async throws {
        let local = f.agent
        f.service.announceAfterNewSession(f.key)
        try assertStoredText(XCTUnwrap(commands().first { $0.state == .pending }))
        XCTAssertEqual(ChatPublishRequest.decode(try assignment().requested)?.auto, true)
        XCTAssertEqual(f.agent, local)
        try await f.journal.queue.write { db in try db.execute(sql: "UPDATE run_commands SET state = 'sent' WHERE type = 'agent.publish'") }
        f.service.settlePublications(f.key)
        XCTAssertEqual(try assignment().name, local.name)
        XCTAssertEqual(try assignment().description, local.description)
        try await source.names.rename("Refactor auth", for: source.record.nameKey)
        XCTAssertEqual(f.service.publishStatus(f.agent, key: f.key).status, .published(teams: []),
            "Rename does not make an existing publication unavailable")
        try await f.journal.queue.write { db in try db.execute(sql: "UPDATE assignments SET published_session = 'old'") }
        f.service.announceAfterNewSession(f.key)
        try assertStoredText(XCTUnwrap(commands().last { $0.state == .pending }))
        XCTAssertEqual(f.agent, local)
    }

    func testPublicationRetriesKeepPrefixNamesAndLongDescriptions() throws {
        f.agent.name = "private-title"
        f.agent.description = String(title.prefix(90))
        for all in [false, true] {
            try f.journal.queue.write { try $0.execute(sql: "DELETE FROM run_commands") }
            let original = try storedCommand(state: .unconfirmed)
            if all { f.service.resendPublications(f.key) }
            else { try f.service.resendPublication(f.agent.id, key: f.key) }
            let records = try commands()
            XCTAssertEqual(records.map(\.state), [.dropped, .pending])
            let resent = try XCTUnwrap(records.last)
            try assertStoredText(resent)
            let originalArgs = try JSONDecoder().decode(ChatCommandEnvelope.self, from: original.bodyBytes).args
            XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: resent.bodyBytes).args, originalArgs)
        }
    }

    func testExplicitRepublicationKeepsStoredText() throws {
        try f.service.publish([f.agent], teams: f.service.myTeams(f.key).map(\.teamId), key: f.key)
        try assertStoredText(XCTUnwrap(commands().last { $0.state == .pending }))
    }

    func testFolderPublicationWithoutSourceReplaysConfirmedLegacyValues() throws {
        f.agent.sessionId = nil
        f.agent.sessionTitle = nil
        try FileManager.default.removeItem(at: source.store.claudeProjectsRoot)
        // Old provenance fields must have no effect, including explicit false.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.agent)) as? [String: Any])
        legacy["nameWasEdited"] = false
        legacy["descriptionWasEdited"] = false
        legacy["publicationSourceConversationID"] = source.record.conversationId
        f.agent = try JSONDecoder().decode(TeamPublishedAgent.self, from: JSONSerialization.data(withJSONObject: legacy))
        try f.assign()
        f.service.announceAfterNewSession(f.key)
        try assertStoredText(XCTUnwrap(commands().last { $0.state == .pending }))
    }

    func testJournalWithRetiredPublicationMetadataStillOpensWithoutChangingText() throws {
        try f.journal.queue.write { db in
            try db.execute(sql: "ALTER TABLE assignments ADD COLUMN name_was_edited BOOLEAN")
            try db.execute(sql: "ALTER TABLE assignments ADD COLUMN description_was_edited BOOLEAN")
            try db.execute(sql: "UPDATE assignments SET name_was_edited = 0, description_was_edited = 0")
        }
        let reopened = try ChatJournal.open(files: f.service.files)
        let row = try XCTUnwrap(reopened.assignment(f.key, agentId: f.agent.id.uuidString.lowercased()))
        XCTAssertEqual(row.name, f.agent.name)
        XCTAssertEqual(row.description, f.agent.description)
    }

    func testReopenedOutboxAndNetworkRetryReplayExactStoredPublicationBytes() async throws {
        let original = try storedCommand()
        try await source.names.rename("New session name", for: source.record.nameKey)
        let attempts = Counter()
        ChatStubProtocol.reset { _, _ in
            attempts.increment()
            return attempts.value == 1 ? .failure(URLError(.networkConnectionLost))
                : .success(.init(status: 200, body: Data(#"{"events":[],"result":{}}"#.utf8)))
        }
        let box = try sender(reopened: true)
        box.allow(connection: 1, generation: "g1")
        try await waitUntil { try self.commands().contains { $0.state == .sent } }
        let sent = try XCTUnwrap(commands().first)
        try assertStoredText(sent)
        XCTAssertEqual(try commands().count, 1)
        XCTAssertEqual(sent.commandId, original.commandId)
        XCTAssertEqual(sent.bodyBytes, original.bodyBytes)
        XCTAssertEqual(ChatStubProtocol.seen.map(\.body), [original.bodyBytes, original.bodyBytes])
        f.service.settlePublications(f.key)
        XCTAssertEqual(try assignment().description, title)
    }

    func testGenericQueueResendsPreservePublicationArguments() async throws {
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: Data(#"{"events":[],"result":{}}"#.utf8))) }
        for all in [false, true] {
            try await f.journal.queue.write { try $0.execute(sql: "DELETE FROM run_commands") }
            let original = try storedCommand(state: .unconfirmed)
            let box = try sender()
            if all { _ = try box.resendUnconfirmed() }
            else { _ = try box.resend(original.commandId) }
            box.allow(connection: 1, generation: "g1")
            try await waitUntil { try self.commands().contains { $0.state == .sent } }
            box.hold()
            let sent = try XCTUnwrap(commands().last { $0.state == .sent })
            try assertStoredText(sent)
            let originalArgs = try JSONDecoder().decode(ChatCommandEnvelope.self, from: original.bodyBytes).args
            XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: sent.bodyBytes).args, originalArgs)
        }
    }

    func testOrdinaryChatPostRetainsExactBytesIncludingAlreadySentTitle() async throws {
        let box = try sender(), id = ChatUUID.v7()
        let bytes = try ChatCommandEnvelope(commandId: id, org: f.key.orgId, type: "message.post",
            args: .object(["text": .string(title), "channel_id": .string("channel")])).encoded() + Data("\n  ".utf8)
        _ = try f.store.outbox.enqueue(.init(commandId: id, sessionId: "s-anna", type: "message.post", bodyBytes: bytes,
            orderKey: "channel", dependsOn: nil, createdAt: Date(), state: .pending))
        let attempts = Counter()
        ChatStubProtocol.reset { _, _ in
            attempts.increment()
            return attempts.value == 1 ? .failure(URLError(.networkConnectionLost))
                : .success(.init(status: 200, body: Data(#"{"events":[],"result":{}}"#.utf8)))
        }
        box.allow(connection: 1, generation: "g1")
        try await waitUntil { try self.f.store.commands().contains { $0.commandId == id && $0.state == .sent } }
        XCTAssertEqual(ChatStubProtocol.seen.map(\.body), [bytes, bytes])
    }
}
