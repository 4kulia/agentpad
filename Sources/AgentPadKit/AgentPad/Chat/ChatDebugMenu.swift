#if DEBUG
import AppKit

/// Debug menu: send `member.set_name` by hand (docs/agentpad/CHAT-PLAN.md
/// C2). Signing in goes only through the connection window (review C13-3).
@MainActor
enum ChatDebugMenu {
    static func setName() {
        Task {
            let service = ChatService.shared
            guard let key = service.connection?.orgKey else {
                return await TeamUI.showError("Not signed in to a server", nil)
            }
            guard let name = await ask("member.set_name", "Your display name in the organization.", [""])?.first else { return }
            do {
                let record = try service.enqueue(key, type: "member.set_name", args: .object(["name": .string(name)]))
                let deadline = ContinuousClock.now + .seconds(15)
                var state = record.state, error: String?
                while state == .pending, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(250))
                    let now = try service.session(for: key).store?.commands().first { $0.commandId == record.commandId }
                    state = now?.state ?? state
                    error = now?.error
                }
                await TeamUI.showError("member.set_name: \(state.rawValue)\(error.map { " (\($0))" } ?? "")", nil)
            } catch {
                await TeamUI.showError("member.set_name failed", error)
            }
        }
    }

    static func disconnect() {
        Task { await ChatService.shared.disconnect() }
    }

    private static func ask(_ title: String, _ text: String, _ defaults: [String]) async -> [String]? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let fields = defaults.map { value -> NSTextField in
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.stringValue = value
            return field
        }
        let stack = NSStackView(views: fields)
        stack.orientation = .vertical
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: CGFloat(fields.count) * 30)
        alert.accessoryView = stack
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard await TeamUI.present(alert) == .alertFirstButtonReturn else { return nil }
        return fields.map(\.stringValue)
    }
}
#endif
