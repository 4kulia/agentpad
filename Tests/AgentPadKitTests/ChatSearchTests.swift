import Foundation
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatSearchTests: XCTestCase {
    private let server = try! ChatServerAddress(parsing: "https://chat.example.com")
    private var key: ChatOrgKey { .init(server: server, accountId: "account", orgId: "org") }
    private func hit(_ kind: ChatSearchHit.Kind = .channel, id: String = "one") -> ChatSearchHit {
        .init(kind: kind, targetID: "place", messageID: id, messageSeq: 17, revision: 2, authorAccountID: "person", createdAt: "2026-10-09T12:00:00Z", snippet: "release checklist")
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Search did not settle")
    }
    func testRequestMatchesContractAndNeverPlacesTextInURL() async throws {
        let page = ChatSearchPage(hits: [hit(.channel), hit(.dm)], next: "opaque")
        let data = try JSONEncoder().encode(page)
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, headers: ["Cache-Control": "no-store"], body: data)) }
        let api = ChatAPI(server: server, protocolClasses: [ChatStubProtocol.self])
        let response = try await api.search("org", request: .init(query: "release checklist", scope: .dm, limit: 20), token: "fixture")
        XCTAssertEqual(response, page); XCTAssertNotEqual(page.hits[0].id, page.hits[1].id)
        let seen = try XCTUnwrap(ChatStubProtocol.seen.first)
        XCTAssertEqual(seen.request.httpMethod, "POST"); XCTAssertEqual(seen.request.url?.path, "/v1/orgs/org/chat/search")
        XCTAssertNil(seen.request.url?.query)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: seen.body) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["query", "scope", "limit"])
        XCTAssertEqual(body["query"] as? String, "release checklist")
    }
    func testNoTeamMissingCapabilitiesAndSessionsModeDoNotFetch() async throws {
        var calls = 0
        for access in [ChatSearchAvailability.noTeam, .unsupported, .offline, .checking] {
            let model = ChatSearchModel(context: { nil }, availability: { access }, fetch: { _, _ in calls += 1; return .init(hits: [], next: nil) })
            model.search(.init(query: "release"), debounce: false)
            XCTAssertFalse(model.loading); XCTAssertTrue(model.hits.isEmpty)
        }
        XCTAssertEqual(calls, 0)
    }
    func testLateReplyCannotRestoreChangedAccountGenerationOrQuery() async throws {
        var context = ChatSearchContext(key: key, session: "s", generation: "g1", revision: 0)
        var continuation: CheckedContinuation<ChatSearchPage, Error>?
        let model = ChatSearchModel(context: { context }, availability: { .ready }, fetch: { _, _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        })
        model.search(.init(query: "release"), debounce: false)
        try await wait { continuation != nil }
        context.generation = "g2"; model.checkContext()
        continuation?.resume(returning: .init(hits: [hit()], next: "stale"))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(model.hits.isEmpty); XCTAssertNil(model.next); XCTAssertFalse(model.loading)
    }
    func testIndependentPaginationDeduplicatesFullIdentityAndReportsFailure() async throws {
        let context = ChatSearchContext(key: key, session: "s", generation: "g", revision: 0)
        var count = 0
        let model = ChatSearchModel(context: { context }, availability: { .ready }, fetch: { [self] _, request in
            count += 1
            if count == 1 { XCTAssertNil(request.cursor); return .init(hits: [hit()], next: "next") }
            if count == 2 { XCTAssertEqual(request.cursor, "next"); return .init(hits: [hit(), hit(.dm)], next: "last") }
            throw ChatAPIError.server(status: 429, code: "rate_limited", retryAfter: 15)
        })
        model.search(.init(query: "release"), debounce: false); try await wait { !model.loading }
        model.search(.init(query: "release"), more: true, debounce: false); try await wait { !model.loading }
        XCTAssertEqual(model.hits.count, 2)
        model.search(.init(query: "release"), more: true, debounce: false); try await wait { !model.loading }
        XCTAssertEqual(model.hits.count, 2); XCTAssertTrue(model.error?.contains("15") == true)
    }
    func testResponseBoundsAndStrictClientValidation() async throws {
        var oversized = hit(); oversized.snippet = String(repeating: "a", count: 321)
        let data = try JSONEncoder().encode(ChatSearchPage(hits: [oversized], next: nil))
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: data)) }
        let api = ChatAPI(server: server, protocolClasses: [ChatStubProtocol.self])
        do { _ = try await api.search("org", request: .init(query: "release"), token: "fixture"); XCTFail() } catch {}
        XCTAssertThrowsError(try ChatSearchRequest(query: "ok", targetID: UUID().uuidString).validate())
        XCTAssertThrowsError(try ChatSearchRequest(query: "ok", limit: 51).validate())
    }
}
