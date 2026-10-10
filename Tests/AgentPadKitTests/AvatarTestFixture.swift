import Foundation
import XCTest
@testable import AgentPadKit

@MainActor
final class AvatarTestFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("avatars-\(UUID())")
    let key = ChatOrgKey(server: try! ChatServerAddress(parsing: "https://avatars.example"),
                        accountId: "01900000-0000-7000-8000-000000000003", orgId: "01900000-0000-7000-8000-000000000005")
    let service: ChatService
    let store: ChatStore
    var own: ChatAvatarReference { .init(key: key, subject: .account(key.accountId)) }
    init(capable: Bool = true) throws {
        service = ChatService(files: ChatFiles(directory: root), tokens: FakeTokenStore())
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
        service.closeRemoteSession = { _, _ in }
        try service.saveSignIn(.init(server: key.server, accountId: key.accountId, sessionId: "s", deviceName: "Test", orgId: key.orgId), token: "t")
        let session = service.session(for: key)
        store = try XCTUnwrap(session.store)
        try store.setGeneration("g")
        try store.apply(.init(cursors: [:], members: [.init(accountId: key.accountId, handle: "me", name: "Me", role: "member")]), confirmsRights: "s")
        session.snapshotOwed = false
        service.avatarGenerations[key.server] = "g"
        service.serverCapabilities[key.server] = capable ? ["chat.avatars"] : []
    }
    func close() async { await service.disconnect(); try? FileManager.default.removeItem(at: root) }
}
