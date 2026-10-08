import XCTest
@testable import AgentPadKit

/// Tests for `HookServer.parseMessage` — the wire-payload decoder that
/// turns one JSON line off the unix socket into a typed `HookMessage`.
/// Direct in-process parse tests (no subprocess / no socket) so each
/// edge case (malformed JSON, wrong types, missing fields, tool-event
/// variants) is fast + deterministic. `@MainActor` because `HookServer`
/// is `@MainActor` and `parseMessage` inherits the isolation.
@MainActor
final class HookServerTests: XCTestCase {
    private static let surfaceUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: Regression — existing message kinds keep working

    func testParseAgentLifecyclePayload() throws {
        let json = #"{"surface":"\#(Self.surfaceUUID.uuidString)","agent":"claude","event":"running"}"#
        let message = HookServer.parseMessage(data(json))
        guard case let .agent(agent, event, sessionId, _) = message else {
            return XCTFail("Expected .agent, got \(String(describing: message))")
        }
        XCTAssertEqual(agent.id, AgentTemplate.claudeCodeID)
        XCTAssertEqual(event, .running)
        XCTAssertEqual(sessionId, Self.surfaceUUID)
    }

    func testParseEnvPayload() throws {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"env","VIRTUAL_ENV":"/v","CONDA_DEFAULT_ENV":"","NVM_BIN":"","NVM_DIR":"","AGENTPAD_NODE_VERSION":"","https_proxy":"","http_proxy":"","all_proxy":""}
        """#
        let message = HookServer.parseMessage(data(json))
        guard case let .shellEnvironment(env, _) = message else {
            return XCTFail("Expected .shellEnvironment, got \(String(describing: message))")
        }
        XCTAssertEqual(env["VIRTUAL_ENV"], "/v")
    }

    func testParseConversationIdPayload() throws {
        let json = #"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"conversationId","conversationId":"sess_abc"}"#
        let message = HookServer.parseMessage(data(json))
        guard case let .conversationId(conversationId, _, _, _) = message else {
            return XCTFail("Expected .conversationId, got \(String(describing: message))")
        }
        XCTAssertEqual(conversationId, "sess_abc")
    }

    // MARK: Tool event payload — happy paths

    func testParseLifecycleDetails() {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","agent":"claude","event":"running","background_subagents":"2","background_shells":"1"}
        """#
        guard case let .agent(_, event, _, details) = HookServer.parseMessage(data(json)) else {
            return XCTFail("Expected .agent")
        }
        XCTAssertEqual(event, .running)
        XCTAssertEqual(details, HookLifecycleDetails(backgroundSubagents: 2, backgroundShells: 1))
    }

    func testParseToolBatchResolved() {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool_batch","agent":"claude"}
        """#
        guard case let .toolBatchResolved(sessionId) = HookServer.parseMessage(data(json)) else {
            return XCTFail("Expected .toolBatchResolved")
        }
        XCTAssertEqual(sessionId, Self.surfaceUUID)
    }

    func testParseToolCallMainThreadFlag() {
        let flagged = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Bash","identifier":"ls","event":"pre","main_thread":"true"}
        """#
        let plain = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Bash","identifier":"ls","event":"pre"}
        """#
        guard case let .toolCall(_, _, _, _, _, _, _, mainThread) = HookServer.parseMessage(data(flagged)) else {
            return XCTFail("Expected .toolCall")
        }
        XCTAssertTrue(mainThread)
        guard case let .toolCall(_, _, _, _, _, _, _, plainFlag) = HookServer.parseMessage(data(plain)) else {
            return XCTFail("Expected .toolCall")
        }
        XCTAssertFalse(plainFlag, "payloads from older hooks carry no flag")
    }

    func testParseToolCallPrePayload() throws {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Bash","identifier":"git status","event":"pre"}
        """#
        let message = HookServer.parseMessage(data(json))
        guard case let .toolCall(agent, toolName, identifier, event, success, _, sessionId, _) = message else {
            return XCTFail("Expected .toolCall, got \(String(describing: message))")
        }
        XCTAssertEqual(agent.id, AgentTemplate.claudeCodeID)
        XCTAssertEqual(toolName, "Bash")
        XCTAssertEqual(identifier, "git status")
        XCTAssertEqual(event, .pre)
        XCTAssertNil(success, "Pre events should not carry a success flag")
        XCTAssertEqual(sessionId, Self.surfaceUUID)
    }

    func testParseToolCallPostSuccessPayload() throws {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Edit","identifier":"/repo/x.swift","event":"post","success":"true"}
        """#
        let message = HookServer.parseMessage(data(json))
        guard case let .toolCall(_, _, _, event, success, _, _, _) = message else {
            return XCTFail("Expected .toolCall, got \(String(describing: message))")
        }
        XCTAssertEqual(event, .post)
        XCTAssertEqual(success, true)
    }

    func testParseToolCallPostFailurePayload() throws {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Bash","identifier":"missing","event":"post","success":"false"}
        """#
        let message = HookServer.parseMessage(data(json))
        guard case let .toolCall(_, _, _, _, success, _, _, _) = message else {
            return XCTFail("Expected .toolCall, got \(String(describing: message))")
        }
        XCTAssertEqual(success, false)
    }

    // MARK: Tool event payload — rejection paths

    func testParseToolCallRejectsMissingToolName() {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","identifier":"x","event":"pre"}
        """#
        XCTAssertNil(HookServer.parseMessage(data(json)))
    }

    func testParseToolCallRejectsEmptyToolName() {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"","identifier":"x","event":"pre"}
        """#
        XCTAssertNil(HookServer.parseMessage(data(json)))
    }

    func testParseToolCallRejectsMissingIdentifier() {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Bash","event":"pre"}
        """#
        XCTAssertNil(HookServer.parseMessage(data(json)))
    }

    func testParseToolCallAcceptsEmptyIdentifier() {
        // Empty identifier is valid — happens for tools with no input or
        // unknown tool kinds whose first-string fallback returned nothing.
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Bash","identifier":"","event":"pre"}
        """#
        let message = HookServer.parseMessage(data(json))
        guard case .toolCall = message else {
            return XCTFail("Expected .toolCall with empty identifier, got \(String(describing: message))")
        }
    }

    func testParseToolCallRejectsUnknownAgentSlug() {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"unknown-agent","tool_name":"Bash","identifier":"x","event":"pre"}
        """#
        XCTAssertNil(HookServer.parseMessage(data(json)))
    }

    func testParseToolCallRejectsUnknownEvent() {
        // event must be "pre" or "post" — anything else is malformed wire.
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Bash","identifier":"x","event":"mid"}
        """#
        XCTAssertNil(HookServer.parseMessage(data(json)))
    }

    func testParseToolCallPostWithMalformedSuccessFlagDefaultsToFalse() {
        // success field present but not "true" — treated as false (only
        // exact "true" passes the equality check). This is the v1
        // permissive contract: garbage in the success slot doesn't reject
        // the whole message.
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Bash","identifier":"x","event":"post","success":"yes"}
        """#
        let message = HookServer.parseMessage(data(json))
        guard case let .toolCall(_, _, _, _, success, _, _, _) = message else {
            return XCTFail("Expected .toolCall, got \(String(describing: message))")
        }
        XCTAssertEqual(success, false)
    }

    func testParseToolCallPostWithMissingSuccessFlagIsNil() {
        // No success field at all on .post — message still parses; success
        // ends up nil. Consumer falls back to its own default (true per
        // WorkspaceStore.applyToolCallEvent).
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Bash","identifier":"x","event":"post"}
        """#
        let message = HookServer.parseMessage(data(json))
        guard case let .toolCall(_, _, _, _, success, _, _, _) = message else {
            return XCTFail("Expected .toolCall, got \(String(describing: message))")
        }
        XCTAssertNil(success)
    }

    func testParseRejectsMalformedJSON() {
        XCTAssertNil(HookServer.parseMessage(Data("{{not json".utf8)))
    }

    func testParseRejectsMissingSurface() {
        let json = #"{"kind":"tool","agent":"claude","tool_name":"Bash","identifier":"x","event":"pre"}"#
        XCTAssertNil(HookServer.parseMessage(data(json)))
    }
}
