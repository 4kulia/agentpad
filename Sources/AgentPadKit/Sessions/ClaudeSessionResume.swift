import Foundation

/// Claude also accepts search text after --resume. Ordinary session entry
/// points must resolve an exact local transcript before composing that flag.
enum ClaudeSessionResume {
    static func projectsRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let config = environment["CLAUDE_CONFIG_DIR"].flatMap { path -> URL? in
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return config?.appendingPathComponent("projects") ?? TeamSessionFiles.root
    }

    enum Refusal: Error, Equatable, LocalizedError {
        case fullIdRequired
        case notFound
        case channelConversation

        var errorDescription: String? { message }
        var message: String {
            switch self {
            case .fullIdRequired:
                "Claude Code Resume requires a full session UUID; names, searches and partial IDs are not accepted."
            case .notFound:
                "The Claude Code session was not found on this Mac. Use the full ID of an existing session."
            case .channelConversation:
                "This conversation is only available through its channel."
            }
        }

        /// Restored tabs have no request caller to receive a refusal. Show it
        /// in their shell, without starting Claude or its conversation picker.
        var shellCommand: String {
            "printf '%s\\n' \(AgentPadShellIntegration.quote(message)); false"
        }
    }

    static func isFullId(_ id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return id.lowercased() == uuid.uuidString.lowercased()
    }

    static func resolve(
        _ id: String,
        root: URL = projectsRoot(),
        visibility: ChannelConversationFilter = .current()
    ) -> Result<String, Refusal> {
        guard isFullId(id) else { return .failure(.fullIdRequired) }
        guard visibility.allows(conversationId: id, root: root) else { return .failure(.channelConversation) }
        guard let file = AgentSessionScanner.claudeTranscript(conversationId: id, root: root),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { return .failure(.notFound) }
        // Keep the spelling found on disk, rather than forwarding caller text.
        return .success(file.deletingPathExtension().lastPathComponent)
    }
}
