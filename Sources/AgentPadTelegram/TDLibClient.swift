import Foundation
import TDLibFramework

/// The protocol seam deliberately exposes JSON values, not vendor Swift DTOs.
/// Integer identifiers never round-trip through Double.
public indirect enum TDLibValue: Codable, Sendable, Equatable {
    case string(String), integer(Int64), decimal(Double), bool(Bool), object([String: TDLibValue]), array([TDLibValue]), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Int64.self) { self = .integer(value) }
        else if let value = try? c.decode(Double.self) { self = .decimal(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([String: TDLibValue].self) { self = .object(value) }
        else { self = .array(try c.decode([TDLibValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .decimal(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int64? {
        switch self { case .integer(let value): value; case .string(let value): Int64(value); default: nil }
    }
    var object: TDLibMessage? { if case .object(let value) = self { TDLibMessage(value) } else { nil } }
    var bool: Bool { if case .bool(let value) = self { value } else { false } }
    var array: [TDLibValue] { if case .array(let value) = self { value } else { [] } }
}

public struct TDLibMessage: Codable, Sendable, Equatable {
    var fields: [String: TDLibValue]
    public init(_ fields: [String: TDLibValue]) { self.fields = fields }
    public init(_ type: String, _ fields: [String: TDLibValue] = [:]) {
        self.fields = fields; self.fields["@type"] = .string(type)
    }
    public init(from decoder: any Decoder) throws { fields = try [String: TDLibValue](from: decoder) }
    public func encode(to encoder: any Encoder) throws { try fields.encode(to: encoder) }
    public subscript(_ key: String) -> TDLibValue? { get { fields[key] } set { fields[key] = newValue } }
    public var type: String { fields["@type"]?.string ?? "" }
}

public protocol TDLibClient: Sendable {
    func send(_ request: TDLibMessage) throws
    /// Blocking. Called exclusively on the receive queue, never on an actor.
    func receive(timeout: TimeInterval) throws -> TDLibMessage?
    /// Release the process receive lease only after authorizationStateClosed.
    /// TDLib's modern C API destroys its client automatically on Closed.
    func release()
}

enum TDLibTransportError: Error { case alreadyRunning, malformed, oversized }

final class TDLibJSONClient: TDLibClient, @unchecked Sendable {
    private static let lease = NSLock()
    nonisolated(unsafe) private static var leased = false
    private let id: Int32
    private var released = false // guarded by lease

    init() throws {
        Self.lease.lock()
        defer { Self.lease.unlock() }
        guard !Self.leased else { throw TDLibTransportError.alreadyRunning }
        Self.leased = true
        // Execute only before the receiver starts: receive/execute share C
        // pointer lifetime. Raw TDLib logging may include tokens or text.
        for json in [#"{"@type":"setLogStream","log_stream":{"@type":"logStreamEmpty"}}"#,
                     #"{"@type":"setLogVerbosityLevel","new_verbosity_level":0}"#] {
            json.withCString { _ = td_execute($0) }
        }
        id = td_create_client_id()
    }

    func send(_ request: TDLibMessage) throws {
        let bytes = try JSONEncoder().encode(request)
        String(decoding: bytes, as: UTF8.self).withCString { td_send(id, $0) }
    }

    func receive(timeout: TimeInterval) throws -> TDLibMessage? {
        guard let pointer = td_receive(timeout) else { return nil }
        let cap = 32 * 1024 * 1024
        let count = strnlen(pointer, cap + 1)
        // History is paginated: back off the SAME request cursor before
        // allocating a large JSON tree. A single huge message remains an
        // explicit unavailable page at limit=1, without a connector restart.
        if count > 2 * 1024 * 1024,
           let result = TDLibEnvelope.oversizedHistory(pointer, count: count > cap ? strlen(pointer) : count, client: Int64(id)) { return result }
        guard count <= cap else { throw TDLibTransportError.oversized }
        // Own the bytes and decode before any subsequent receive/execute.
        let bytes = Data(bytes: pointer, count: count)
        guard let message = try? JSONDecoder().decode(TDLibMessage.self, from: bytes) else {
            throw TDLibTransportError.malformed
        }
        guard message["@client_id"]?.integer == Int64(id) else { return nil }
        return message
    }

    func release() {
        Self.lease.lock(); defer { Self.lease.unlock() }
        guard !released else { return }
        released = true; Self.leased = false
    }
}

final class TDLibReceiveQueue: Sendable {
    private let queue = DispatchQueue(label: "com.4kulia.agentpad.telegram.receive", qos: .utility)
    private let client: any TDLibClient
    init(client: any TDLibClient) { self.client = client }
    func next() async throws -> TDLibMessage? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [client] in
                continuation.resume(with: Result { try autoreleasepool { try client.receive(timeout: 0.1) } })
            }
        }
    }
}
