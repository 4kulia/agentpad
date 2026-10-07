import Foundation

/// Exercises the reaction picker's real resource lookup before any app state
/// or UI is opened. Run the packaged executable with --self-check-emoji-resources.
public enum AgentPadResourceSelfCheck {
    public static func run() -> Bool {
        let bundle = agentPadResourceBundle()
        let resource = bundle?.url(forResource: "emoji-16.0", withExtension: "json")
        let aliases = ChatEmoji.aliases
        print("Emoji resource: \(resource?.path ?? "missing")")
        print("Emoji aliases: \(aliases.count)")

        let expectedBundle = Bundle.main.resourceURL?
            .appendingPathComponent("AgentPad_AgentPadKit.bundle").standardizedFileURL
        guard let expectedBundle, bundle?.bundleURL.standardizedFileURL == expectedBundle else {
            print("FAIL: resource bundle must be inside Contents/Resources")
            return false
        }
        guard resource != nil, aliases.count > 4000,
              ChatEmoji.quick.allSatisfy({ ChatEmoji.canonical($0) == $0 }),
              ChatEmoji.canonical("❤") == "❤️" else {
            print("FAIL: emoji aliases are missing or invalid")
            return false
        }
        print("PASS: packaged emoji resources")
        return true
    }
}
