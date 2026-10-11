import AgentPadHookKit
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatToolValidationTests: XCTestCase {
    func testDirectChatEntryVerifiesBeforeValidatingArguments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-validation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ChatService(files: .init(directory: root), tokens: FakeTokenStore())
        let caller = ChatLocalCaller(surface: UUID().uuidString, claudePID: 123, claudeStart: 1, signature: "Tab")
        for args: ChatJSON in [.object(["tool": .string("chat_post"), "message_id": .string("bad")]),
                               .object(["tool": .string("chat_read"), "kind": .string("dm"), "dm_id": .string("bad")])] {
            var verified = false
            do {
                _ = try await ChatSessionTools.call(args, caller: caller, service: service, revalidate: { verified = true; return false })
                XCTFail("An unverified caller cannot execute a tool")
            } catch let failure as ChatSessionTools.Failure {
                XCTAssertTrue(verified)
                XCTAssertNotEqual(failure.code, "invalid_args")
                XCTAssertNil(failure.field)
            }
        }
    }

    func testVerifiedSocketReturnsFieldErrorsBeforeNetworkAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-validation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ChatService(files: .init(directory: root), tokens: FakeTokenStore())
        let processes = AnswerProcessFixture()
        let engine = TestEngine()
        engine.foregroundPid = AnswerProcessFixture.claude
        let tab = Session(engine: engine, currentDirectory: root, agent: .terminal)
        let id = UUID().uuidString
        for (text, message, field, detail) in [
            ("hello", "not-a-uuid", "message_id", "message_id must be a UUID"),
            (String(repeating: "x", count: 16_385), id, "text", "text must be at most 16384 UTF-8 bytes"),
        ] {
            var request = AgentPadCLIRequest(verb: .team)
            request.teamAction = "chat"
            request.chatArguments = String(decoding: try JSONSerialization.data(withJSONObject: [
                "tool": "chat_post", "org_id": id, "channel_id": id, "text": text, "message_id": message,
            ]), as: UTF8.self)
            let response = await ChatSessionTools.handle(request,
                origin: .localProcess(pid: AnswerProcessFixture.hook, startedAtUs: 100), sessions: { [tab] }, service: service,
                signatureVerifier: processes.inspector.signed, scan: processes.inspector.scan, kernel: processes.inspector.kernel)
            XCTAssertFalse(response.ok)
            let result = try JSONDecoder().decode(ChatJSON.self, from: Data(try XCTUnwrap(response.chatResult).utf8))
            XCTAssertEqual(result["error"]?.string, "invalid_args")
            XCTAssertEqual(result["field"]?.string, field)
            XCTAssertEqual(result["message"]?.string, detail)
        }
    }

    func testUnverifiedSocketNeverReceivesArgumentDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-validation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ChatService(files: .init(directory: root), tokens: FakeTokenStore())
        for raw: String? in [nil, "{", "[]", "{}", String(repeating: "x", count: 24 * 1024 + 1),
                            #"{"tool":"chat_post","text":42}"#,
                            #"{"tool":"chat_read","kind":"dm","dm_id":"invalid"}"#,
                            #"{"tool":"chat_channels","scope":"members","after":42}"#,
                            #"{"tool":"chat_read","attachment_id":"invalid"}"#] {
            var request = AgentPadCLIRequest(verb: .team)
            request.teamAction = "chat"
            request.chatArguments = raw
            let privateAccess = raw?.contains("dm_id") == true || raw?.contains("members") == true || raw?.contains("attachment_id") == true
            for origin in [AgentPadCallerOrigin.outside, .localProcess(pid: 99_999_999, startedAtUs: 1)] {
                let response = await ChatSessionTools.handle(request, origin: origin, sessions: { [] }, service: service)
                XCTAssertFalse(response.ok)
                let result = try JSONDecoder().decode(ChatJSON.self, from: Data(try XCTUnwrap(response.chatResult).utf8))
                XCTAssertEqual(result["error"]?.string, privateAccess ? "dm_not_allowed" : "session_process_unavailable")
                XCTAssertNil(result["field"])
            }
        }
    }
}
