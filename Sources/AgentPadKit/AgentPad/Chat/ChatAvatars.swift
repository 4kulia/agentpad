import AppKit
import ImageIO

struct ChatAvatarMetadata: Codable, Equatable, Hashable, Sendable {
    let revision: Int
    let imageId: String?
    enum CodingKeys: String, CodingKey { case revision, imageId = "image_id" }
    var valid: Bool { revision >= 0 && (imageId == nil || UUID(uuidString: imageId!) != nil) }
}

struct ChatAvatarLimits: Codable, Equatable, Sendable {
    var imageBytes = 245_760
    var imageSide = 512
    var imagePixels = 262_144
    enum CodingKeys: String, CodingKey { case imageBytes = "image_bytes", imageSide = "image_side", imagePixels = "image_pixels" }
    var bytes: Int { min(245_760, max(1, imageBytes)) }
    var side: Int { min(512, max(1, imageSide), Int(sqrt(Double(max(1, imagePixels))))) }
}

enum ChatAvatarSubject: Hashable, Sendable {
    case account(String), agent(String)
    var id: String { switch self { case .account(let id), .agent(let id): id } }
    func path(in key: ChatOrgKey) throws -> String {
        guard UUID(uuidString: id) != nil, UUID(uuidString: key.orgId) != nil else { throw ChatAPIError.unexpectedAnswer("invalid avatar subject") }
        switch self {
        case .account(let id) where id == key.accountId: return "/v1/account/avatar"
        case .account(let id): return "/v1/orgs/\(key.orgId)/accounts/\(id)/avatar"
        case .agent(let id): return "/v1/orgs/\(key.orgId)/agents/\(id)/avatar"
        }
    }
}

struct ChatAvatarReply: Codable, Equatable, Sendable {
    let generation: String
    var commandId: String? = nil
    var accountId: String? = nil
    var orgId: String? = nil
    var agentId: String? = nil
    var appliedRevision: Int? = nil
    let avatar: ChatAvatarMetadata
    enum CodingKeys: String, CodingKey {
        case generation, avatar
        case commandId = "command_id", accountId = "account_id", orgId = "org_id", agentId = "agent_id", appliedRevision = "applied_revision"
    }
    func matches(_ subject: ChatAvatarSubject, key: ChatOrgKey, generation: String, write: ChatAvatarCommand? = nil) -> Bool {
        guard self.generation == generation, avatar.valid else { return false }
        switch subject {
        case .account(let id): guard accountId == id, agentId == nil, orgId == nil || orgId == key.orgId else { return false }
        case .agent(let id): guard agentId == id, orgId == key.orgId else { return false }
        }
        if let write {
            guard commandId == write.id, accountId == key.accountId, let appliedRevision,
                  appliedRevision == write.expectedRevision + 1, avatar.revision >= appliedRevision else { return false }
        }
        return true
    }
}

/// Retained verbatim in memory until the server resolves an ambiguous response.
struct ChatAvatarCommand: Equatable, Sendable {
    var id = ChatUUID.v7()
    let expectedRevision: Int
    let generation: String
    let data: Data?
}

enum ChatAvatarImage {
    static func prepare(_ source: CGImage, crop: AvatarCrop = .init(), limits: ChatAvatarLimits = .init(), maxSide: Int = 512) throws -> Data {
        var side = min(limits.side, max(1, maxSide))
        while true {
            let bytes = try LocalAvatarImage.png(source, crop: crop, side: side)
            if bytes.count <= limits.bytes { return bytes }
            guard side > 1 else { throw LocalAvatarError.size }
            side = max(1, side * 4 / 5)
        }
    }
    static func read(_ data: Data, limits: ChatAvatarLimits = .init()) throws -> CGImage {
        guard data.count <= limits.bytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == height, width > 0, width <= limits.side else { throw LocalAvatarError.size }
        return try LocalAvatarImage.decode(data)
    }
}

extension ChatAPI {
    private func avatarRequest(_ subject: ChatAvatarSubject, key: ChatOrgKey, token: String,
                               image: String? = nil, command: ChatAvatarCommand? = nil) async throws -> Response {
        guard key.server == server else { throw ChatAPIError.unexpectedAnswer("avatar server changed") }
        var path = try subject.path(in: key)
        if let image {
            guard UUID(uuidString: image) != nil else { throw ChatAPIError.unexpectedAnswer("invalid image ID") }
            path += "/\(image)"
        }
        if command != nil, case .account(let id) = subject, id != key.accountId { throw ChatAPIError.unexpectedAnswer("another account's avatar is read-only") }
        var request = URLRequest(url: server.baseURL.appendingPathComponent(path))
        request.timeoutInterval = 30
        request.httpMethod = command.map { $0.data == nil ? "DELETE" : "PUT" } ?? "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(image == nil ? "application/json" : "image/png", forHTTPHeaderField: "Accept")
        if let command {
            guard command.expectedRevision >= 0, (command.data?.count ?? 0) <= 245_760 else { throw LocalAvatarError.size }
            request.setValue(command.id, forHTTPHeaderField: "X-Command-Id")
            request.setValue(command.generation, forHTTPHeaderField: "X-AgentPad-Generation")
            request.setValue("\"\(command.expectedRevision)\"", forHTTPHeaderField: "If-Match")
            if let data = command.data {
                _ = try ChatAvatarImage.read(data)
                request.setValue("image/png", forHTTPHeaderField: "Content-Type")
                request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
            }
        }
        let result = try await avatarTransfer(request, upload: command?.data, limit: image == nil ? 64 * 1024 : 245_760)
        try Self.check(result)
        return result
    }
    func avatarMetadata(_ subject: ChatAvatarSubject, key: ChatOrgKey, generation: String, token: String) async throws -> ChatAvatarReply {
        let response = try await avatarRequest(subject, key: key, token: token)
        let reply = try JSONDecoder().decode(ChatAvatarReply.self, from: response.body)
        guard reply.matches(subject, key: key, generation: generation) else { throw ChatAPIError.unexpectedAnswer("avatar context changed") }
        return reply
    }
    func avatarWrite(_ subject: ChatAvatarSubject, key: ChatOrgKey, command: ChatAvatarCommand, token: String) async throws -> ChatAvatarReply {
        let response = try await avatarRequest(subject, key: key, token: token, command: command)
        let reply = try JSONDecoder().decode(ChatAvatarReply.self, from: response.body)
        guard reply.matches(subject, key: key, generation: command.generation, write: command) else { throw ChatAPIError.unexpectedAnswer("avatar receipt does not match") }
        return reply
    }
    func avatarImage(_ subject: ChatAvatarSubject, key: ChatOrgKey, metadata: ChatAvatarMetadata, generation: String, token: String) async throws -> Data {
        guard let image = metadata.imageId, metadata.valid else { throw LocalAvatarError.damaged }
        let response = try await avatarRequest(subject, key: key, token: token, image: image)
        guard response.headers["x-agentpad-generation"] == generation,
              response.headers["x-avatar-revision"] == String(metadata.revision),
              response.headers["content-type"]?.split(separator: ";").first == "image/png" else { throw ChatAPIError.unexpectedAnswer("avatar image version changed") }
        _ = try ChatAvatarImage.read(response.body)
        return response.body
    }
}
