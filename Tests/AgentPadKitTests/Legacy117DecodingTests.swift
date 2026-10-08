import Foundation
import XCTest
@testable import AgentPadKit

/// Literal pre-attachment/pre-tab-transfer JSON, independent of today's encoder.
/// The audit covers every existing Codable shape changed since ae8bc9f.
@MainActor
final class Legacy117DecodingTests: XCTestCase {
    private let messageJSON = """
        {
          "messageId":"message","channelId":"channel","threadRootId":"root",
          "authorAccountId":"owner","seq":7,"createdAt":"2026-10-05T09:00:00Z",
          "hasFixed":true,"hasMutable":true,"text":"","mentions":["member"],"revision":3,
          "editedAt":"2026-10-05T09:01:00Z","deletedAt":"2026-10-05T09:02:00Z",
          "authorAgentId":"agent","authorAgentName":"Helper","authorSessionName":"Session",
          "inReplyToMessageId":"previous","stale":4,"localState":"failed","localError":"offline",
          "localEdit":{"kind":"edit","text":"unsaved","state":"failed","error":"conflict"}
        }
        """
    private let inputsJSON = """
        {
          "agentId":"agent","folder":"/tmp/project","access":"read","deniedPaths":["private"],
          "allowedCommands":[],"maxTurns":10,"timeoutMinutes":5,"extraFolders":[],
          "requestId":"request","prompt":"Review this","callerName":"Owner",
          "expiresAt":1800000000,"termsVersion":2
        }
        """

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testChatMessageDefaultsMissingAttachmentKeysAndPreservesEveryLegacyField() throws {
        let message = try decode(ChatMessage.self, messageJSON)
        XCTAssertEqual(message.attachments, [])
        XCTAssertFalse(message.attachmentOnly)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        XCTAssertEqual(encoded.removeValue(forKey: "attachments") as? [String], [])
        XCTAssertEqual(encoded.removeValue(forKey: "attachmentOnly") as? Bool, false)
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(messageJSON.utf8)) as? NSDictionary)
        XCTAssertEqual(encoded as NSDictionary, legacy)
    }

    func testChatMessageDefaultsNullAttachmentKeysAndAbsentOptionalFields() throws {
        let message = try decode(ChatMessage.self, """
            {"messageId":"m","channelId":"c","authorAccountId":"a","createdAt":"now",
             "hasFixed":true,"hasMutable":true,"text":"text","mentions":[],"revision":1,
             "attachments":null,"attachmentOnly":null}
            """)
        XCTAssertEqual(message.attachments, [])
        XCTAssertFalse(message.attachmentOnly)
        XCTAssertNil(message.threadRootId)
        XCTAssertNil(message.localEdit)
        XCTAssertNil(message.localState)
        XCTAssertEqual(message.text, "text")
    }

    func testChatMessagePreservesCurrentAttachmentFieldsOnRoundTrip() throws {
        var message = try decode(ChatMessage.self, messageJSON)
        message.deletedAt = nil
        message.attachments = [ChatAttachment(attachmentId: "file", position: 0, name: "notes.txt",
                                             mime: "text/plain", size: 10, hasPreview: false)]
        message.attachmentOnly = true
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message)), message)
    }

    func testChatMessageStillRejectsMissingOriginalFieldsAndMalformedAttachments() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(messageJSON.utf8)) as? [String: Any])
        for key in ["messageId", "channelId", "authorAccountId", "createdAt", "hasFixed", "hasMutable", "text", "mentions", "revision"] {
            var json = original
            json.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: json)), key)
        }
        for (key, value) in [("attachments", "invalid"), ("attachmentOnly", "invalid")] {
            var json = original
            json[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: json)), key)
        }
    }

    func testServerMessagesWithoutAttachmentsDecodeInsidePage() throws {
        let page = try decode(ChatMessagesPage.self, """
            {"messages":[{"message_id":"m","channel_id":"c","author_account_id":"a",
              "text":"Old server text","mentions":[],"revision":2,"seq":3,"created_at":"now"}],
             "next":null,"head":3}
            """)
        let message = try XCTUnwrap(page.messages.first)
        XCTAssertEqual(message.text, "Old server text")
        XCTAssertEqual(message.attachments, [])
        XCTAssertFalse(message.attachmentOnly)
    }

    func testServerInfoWithoutAttachmentLimitsDecodes() throws {
        let info = try decode(ChatServerInfo.self, """
            {"name":"AgentPad","version":"1.1.7","generation":"g","api_versions":["v1"],
             "capabilities":["chat.channel_ux1"],
             "limits":{"message":16384,"request":16384,"result":65536,"frame":1048576}}
            """)
        let limits = try XCTUnwrap(info.limits)
        XCTAssertEqual(limits.message, 16384)
        XCTAssertNil(limits.attachments)
    }

    func testChannelContentWithoutAttachmentManifestDecodes() throws {
        let content = try decode(ChatChannelContent.self, """
            {"request_id":"request","text":"Review this",
             "context":[{"message_id":"message","revision":2,"author_account_id":"owner","text":"Context"}]}
            """)
        XCTAssertNil(content.attachments)
        XCTAssertEqual(content.context?.first?.text, "Context")
        XCTAssertEqual(content.requestId, "request")
    }

    func testApprovalInputsWithoutAttachmentsDecodeInsideSavedParams() throws {
        let params = try TeamLaunchParams.decode("""
            {"inputs":\(inputsJSON),"agentName":"Helper","conversationId":"conversation","runId":"run",
             "startCommandId":"command","generation":"g",
             "approvedAt":"2026-10-05T09:00:00Z","expiresAt":"2026-10-05T10:00:00Z"}
            """)
        XCTAssertNil(params.inputs.attachments)
        XCTAssertEqual(params.inputs.prompt, "Review this")
        XCTAssertEqual(params.inputs.deniedPaths, ["private"])
        XCTAssertEqual(params.inputs.termsVersion, 2)
        XCTAssertEqual(params.runId, "run")
    }

    func testChannelAuthorityAndNestedExecutionSettingsWithoutAttachmentsDecode() throws {
        let authority = try decode(ChatChannelAuthority.self, """
            {"id":"consent","server":"https://chat.example.com","account":"owner","org":"org",
             "session":"session","generation":"g","channel":"channel","agent":"agent",
             "basis":"self_call","settings":{"inputs":\(inputsJSON)},
             "request":"request","source":"message","text":"Review this","sourceRevision":2}
            """)
        XCTAssertNil(authority.attachments)
        XCTAssertNil(authority.settings.inputs.attachments)
        XCTAssertEqual(authority.sourceRevision, 2)
        XCTAssertEqual(authority.settings.inputs.access, "read")
    }

    func testRunRecordWithoutLaunchFailureDecodes() throws {
        let run = try decode(ChatRunRecord.self, """
            {"run_id":"run","request_id":"request","approval_id":"approval","agent_id":"agent",
             "conversation_id":"conversation","started_at":100,"outcome":"finished",
             "result_text":"Saved answer","result_erased":false,"channel_revoked":false}
            """)
        XCTAssertNil(run.launchFailure)
        XCTAssertEqual(run.outcome, .finished)
        XCTAssertEqual(run.resultText, "Saved answer")
    }

    func testWorkspaceFileWithoutPerTabSSHHostLoadsFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("legacy117-state-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        try Data("""
            {"windows":[{"id":"00000000-0000-4000-8000-000000000001","state":{"workspaces":[{
              "id":"00000000-0000-4000-8000-000000000002","workingDirectoryPath":"/tmp/project",
              "sshRemoteHost":"example-host","customTitle":"Saved workspace",
              "root":{"id":"00000000-0000-4000-8000-000000000003","kind":{"pane":{
                "id":"00000000-0000-4000-8000-000000000004","tabs":[{
                  "id":"00000000-0000-4000-8000-000000000005","agentId":"terminal",
                  "currentDirectoryPath":"/tmp/project","conversationId":"conversation","customTitle":"Saved tab"
                }],"activeTabId":"00000000-0000-4000-8000-000000000005"
              }}}}]}}]}
            """.utf8).write(to: file)
        let windows = AppPersistence.loadFromDisk(from: file)
        XCTAssertEqual(windows.count, 1)
        let workspace = try XCTUnwrap(windows.first?.state.workspaces.first)
        XCTAssertEqual(workspace.sshRemoteHost, "example-host")
        guard case .pane(let pane) = workspace.root.kind else { return XCTFail("Lost the legacy pane") }
        let tab = try XCTUnwrap(pane.tabs.first)
        XCTAssertNil(tab.sshWorkspaceHost, "Legacy tabs inherit their workspace's connection")
        XCTAssertEqual(tab.customTitle, "Saved tab")
        XCTAssertEqual(tab.conversationId, "conversation")
        XCTAssertEqual(pane.activeTabId, tab.id)
    }

    func testLegacyNotificationAndPromptSettingsKeepDefaultsWithoutNewKeys() throws {
        // Both settings surfaces use dictionaries, not Codable records.
        // AttentionEvent/Marker/Episode are new formats with no 1.1.7 records.
        for enabled in [true, false] {
            let json = """
                {"agents":{"agentPadPrompt":\(enabled)},"notifications":{"enabled":\(enabled),"sound":false}}
                """
            let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(AgentPadAgentPrompt.isEnabled(in: settings), enabled)
            XCTAssertFalse(AgentPadAgentPrompt.isCodexEnabled(in: settings))
            XCTAssertEqual(AgentPadAgentPrompt.additionalInstruction(in: settings), "")
            let values = try XCTUnwrap(settings["notifications"] as? [String: Any])
            let preferences = AttentionPreferences.read(values)
            XCTAssertEqual(preferences.enabled, enabled)
            XCTAssertFalse(preferences.sound)
            XCTAssertTrue(preferences.disabled.isEmpty)
        }
    }

    func testB1MetadataStillReadsLegacyCacheWithNewCustomDecoder() throws {
        let metadata = try decode(ChatB1.Metadata.self, """
            {"message_id":"message","deleted":false,
             "reactions":[{"emoji":"🐇","count":2,"mine":true}],
             "pin":{"pinned_by":"owner","pinned_at":"now"},
             "thread_summary":{"root_id":"message","reply_count":1,
               "last_participants":[{"author_account_id":"owner"}]}}
            """)
        XCTAssertEqual(metadata.reactions, [.init(emoji: "🐇", count: 2, mine: true)])
        XCTAssertEqual(metadata.pin?.pinnedBy, "owner")
        XCTAssertEqual(metadata.threadSummary?.lastParticipants.first?.authorAccountId, "owner")
    }
}
