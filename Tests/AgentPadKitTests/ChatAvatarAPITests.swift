import AppKit
import ImageIO
import XCTest
@testable import AgentPadKit

enum AvatarTestImage {
    static func make(noise: Bool = false, side: Int = 512) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if noise {
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            var seed: UInt32 = 17
            for i in 0..<(context.bytesPerRow * side) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                bytes[i] = i % 4 == 3 ? 255 : UInt8(seed >> 24)
            }
        } else { context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: side, height: side)) }
        return try XCTUnwrap(context.makeImage())
    }
    static func png() throws -> Data { try ChatAvatarImage.prepare(make()) }
}

final class ChatAvatarAPITests: XCTestCase {
    let server = try! ChatServerAddress(parsing: "https://avatars.example")
    let account = "01900000-0000-7000-8000-000000000003"
    let org = "01900000-0000-7000-8000-000000000005"
    let image = "01900000-0000-7000-8000-000000000004"
    var key: ChatOrgKey { .init(server: server, accountId: account, orgId: org) }
    var api: ChatAPI { ChatAPI(server: server, protocolClasses: [ChatStubProtocol.self]) }

    func testPreparationFitsNoiseAndNegotiatedBoundsWithoutMetadata() throws {
        let data = try ChatAvatarImage.prepare(AvatarTestImage.make(noise: true))
        let decoded = try ChatAvatarImage.read(data)
        XCTAssertLessThanOrEqual(data.count, 245_760)
        XCTAssertLessThan(decoded.width, 512); XCTAssertEqual(decoded.width, decoded.height)
        let small = try ChatAvatarImage.prepare(AvatarTestImage.make(noise: true), limits: .init(imageBytes: 16_384, imageSide: 160, imagePixels: 10_000))
        XCTAssertLessThanOrEqual(small.count, 16_384)
        XCTAssertLessThanOrEqual(try ChatAvatarImage.read(small).width, 100)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let info = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(info[kCGImagePropertyExifDictionary]); XCTAssertNil(info[kCGImagePropertyGPSDictionary])
    }

    func testCASUploadAndExactReplayUseDedicatedAuthenticatedPNGRequest() async throws {
        let command = ChatAvatarCommand(expectedRevision: 0, generation: "g", data: try AvatarTestImage.png())
        let reply = ChatAvatarReply(generation: "g", commandId: command.id, accountId: account, appliedRevision: 1,
                                   avatar: .init(revision: 1, imageId: image))
        let body = try JSONEncoder().encode(reply)
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: body)) }
        for _ in 0..<2 { _ = try await api.avatarWrite(.account(account), key: key, command: command, token: "secret") }
        XCTAssertEqual(ChatStubProtocol.seen.count, 2)
        for seen in ChatStubProtocol.seen {
            XCTAssertEqual(seen.request.url?.path, "/v1/account/avatar")
            XCTAssertEqual(seen.request.httpMethod, "PUT")
            XCTAssertEqual(seen.request.value(forHTTPHeaderField: "If-Match"), "\"0\"")
            XCTAssertEqual(seen.request.value(forHTTPHeaderField: "X-Command-Id"), command.id)
            XCTAssertEqual(seen.request.value(forHTTPHeaderField: "X-AgentPad-Generation"), "g")
            XCTAssertEqual(seen.request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(seen.request.value(forHTTPHeaderField: "Content-Type"), "image/png")
            XCTAssertEqual(seen.body, command.data)
        }
    }

    func testDeleteAndExplicit413IncludingNonJSONProxyResponse() async throws {
        let command = ChatAvatarCommand(expectedRevision: 4, generation: "g", data: nil)
        let reply = ChatAvatarReply(generation: "g", commandId: command.id, accountId: account, appliedRevision: 5,
                                   avatar: .init(revision: 5, imageId: nil))
        let body = try JSONEncoder().encode(reply)
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: body)) }
        _ = try await api.avatarWrite(.account(account), key: key, command: command, token: "t")
        XCTAssertEqual(ChatStubProtocol.seen.first?.request.httpMethod, "DELETE")
        XCTAssertEqual(ChatStubProtocol.seen.first?.body, Data())
        ChatStubProtocol.reset { _, _ in .success(.init(status: 413, body: Data("too large".utf8))) }
        do { _ = try await api.avatarWrite(.account(account), key: key, command: command, token: "t"); XCTFail() }
        catch ChatAPIError.server(let status, _, _) { XCTAssertEqual(status, 413) }
    }

    func testWrongScopeAndLateGenerationOrVersionCannotReturnAnImage() async throws {
        let bytes = try AvatarTestImage.png()
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, headers: ["Content-Type": "image/png", "X-Avatar-Revision": "1", "X-AgentPad-Generation": "old"], body: bytes)) }
        do { _ = try await api.avatarImage(.account(account), key: key, metadata: .init(revision: 1, imageId: image), generation: "new", token: "t"); XCTFail() } catch {}
        do { _ = try await api.avatarImage(.account(account), key: key, metadata: .init(revision: 2, imageId: image), generation: "old", token: "t"); XCTFail() } catch {}
        let before = ChatStubProtocol.seen.count
        let wrong = ChatOrgKey(server: try ChatServerAddress(parsing: "https://other.example"), accountId: account, orgId: org)
        do { _ = try await api.avatarMetadata(.account(account), key: wrong, generation: "g", token: "t"); XCTFail() } catch {}
        do { _ = try await api.avatarWrite(.account(image), key: key, command: .init(expectedRevision: 0, generation: "g", data: nil), token: "t"); XCTFail() } catch {}
        XCTAssertEqual(ChatStubProtocol.seen.count, before)
        let reply = ChatAvatarReply(generation: "g", accountId: account, orgId: org, agentId: image, avatar: .init(revision: 1, imageId: image))
        XCTAssertFalse(reply.matches(.account(account), key: key, generation: "g"))
        XCTAssertFalse(reply.matches(.agent(account), key: key, generation: "g"))
    }

    func testLegacyMeAndCardsDecodeWithOmittedAvatar() throws {
        let me = try JSONDecoder().decode(ChatMe.self, from: Data(#"{"account_id":"a","session_id":"s","orgs":[],"streams":{}}"#.utf8))
        XCTAssertNil(me.avatar)
        let card = try JSONDecoder().decode(ChatAgentCard.self, from: Data(#"{"agent_id":"a","owner_account_id":"o","name":"n","description":"","access":"read","enabled":true,"available":true}"#.utf8))
        XCTAssertNil(card.avatar)
    }
    func testOversizedProxyErrorBodyStillReportsExplicit413() async throws {
        ChatStubProtocol.reset { _, _ in .success(.init(status: 413, headers: ["Content-Length": "90000"], body: Data(repeating: 65, count: 90_000))) }
        do {
            _ = try await api.avatarWrite(.account(account), key: key, command: .init(expectedRevision: 0, generation: "g", data: try AvatarTestImage.png()), token: "t")
            XCTFail("Expected 413")
        } catch ChatAPIError.server(let status, _, _) { XCTAssertEqual(status, 413) }
    }

}
