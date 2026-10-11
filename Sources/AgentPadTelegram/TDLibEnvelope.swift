import Foundation

/// Constant-space envelope scan, including @extra after an oversized array.
/// The C pointer stays borrowed until this finishes; receive is serial.
enum TDLibEnvelope {
    static func scan(_ pointer: UnsafePointer<CChar>, count: Int) -> [String: TDLibValue]? {
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        var cursor = 0
        func whitespace() { while cursor < count && [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 } }
        func valueEnd() -> Int? {
            let start = cursor
            var depth = 0, quoted = false, escaped = false
            while cursor < count {
                let c = bytes[cursor]
                if quoted {
                    if escaped { escaped = false }
                    else if c == 92 { escaped = true }
                    else if c == 34 { quoted = false }
                } else {
                    if c == 34 { quoted = true }
                    else if c == 91 || c == 123 { depth += 1 }
                    else if c == 93 || c == 125 {
                        if depth == 0 { return cursor > start ? cursor : nil }
                        depth -= 1
                    } else if c == 44 && depth == 0 { return cursor > start ? cursor : nil }
                }
                cursor += 1
            }
            return !quoted && depth == 0 && cursor > start ? cursor : nil
        }
        whitespace(); guard cursor < count, bytes[cursor] == 123 else { return nil }; cursor += 1
        var result: [String: TDLibValue] = [:]
        while cursor < count {
            whitespace()
            guard cursor < count else { return nil }
            if bytes[cursor] == 125 { return result }
            let start = cursor
            guard bytes[cursor] == 34 else { return nil }
            cursor += 1
            while cursor < count && bytes[cursor] != 34 {
                if bytes[cursor] == 92 { cursor += 1 }
                cursor += 1
            }
            guard cursor < count, cursor - start < 1024 else { return nil }
            cursor += 1
            let keyData = Data(bytes: bytes.advanced(by: start), count: cursor - start)
            guard let key = try? JSONDecoder().decode(String.self, from: keyData) else { return nil }
            whitespace(); guard cursor < count, bytes[cursor] == 58 else { return nil }; cursor += 1; whitespace()
            let valueStart = cursor
            guard let end = valueEnd() else { return nil }
            if ["@type", "@extra", "@client_id"].contains(key), end - valueStart <= 1024 {
                let data = Data(bytes: bytes.advanced(by: valueStart), count: end - valueStart)
                result[key] = try? JSONDecoder().decode(TDLibValue.self, from: data)
            }
            whitespace(); guard cursor < count else { return nil }
            if bytes[cursor] == 125 { return result }
            guard bytes[cursor] == 44 else { return nil }; cursor += 1
        }
        return nil
    }
    static func oversizedHistory(_ pointer: UnsafePointer<CChar>, count: Int, client: Int64) -> TDLibMessage? {
        guard let envelope = scan(pointer, count: count), envelope["@client_id"]?.integer == client,
              ["messages", "forumTopics", "foundChatMessages"].contains(envelope["@type"]?.string ?? ""), let extra = envelope["@extra"]?.string, (extra.hasPrefix("feed:history:") || extra.hasPrefix("chats:background:")) else { return nil }
        return TDLibMessage("error", ["code": .integer(413), "message": .string("page_too_large"), "@extra": .string(extra)])
    }
}
