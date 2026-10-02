import Foundation

/// The editor fetches a pending UI command over the hook socket. Command
/// text never shares the terminal's input stream with the user's keystrokes.
public struct AgentPadShellCommandRequest: Codable, Sendable {
    public static let kind = "shellCommand"
    public let kind: String
    public let surface: UUID
    public let shellPID: Int32

    public init(surface: UUID, shellPID: Int32) {
        self.kind = Self.kind
        self.surface = surface
        self.shellPID = shellPID
    }
}

public struct AgentPadShellCommandResponse: Codable, Sendable {
    public let command: String?

    public init(command: String?) { self.command = command }
}

extension AgentPadHookKit {
    public static func normalizedShellCommand(_ command: String) -> String? {
        let command = command.trimmingCharacters(in: .newlines)
        guard !command.isEmpty, command.utf8.count <= 4096,
              !command.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return command
    }

    public static func fetchShellCommand(
        surface: UUID, shellPID: Int32, socketPath: String = socketPath, timeout: TimeInterval = 1
    ) -> String? {
        guard shellPID > 0,
              let line = AgentPadCLIProtocol.encodeLine(AgentPadShellCommandRequest(surface: surface, shellPID: shellPID)),
              case .success(let reply) = AgentPadCLITransport.roundTrip(line: line, socketPath: socketPath, timeout: timeout),
              let response = AgentPadCLIProtocol.decodeLine(AgentPadShellCommandResponse.self, from: reply),
              let command = response.command else { return nil }
        return normalizedShellCommand(command)
    }
}
