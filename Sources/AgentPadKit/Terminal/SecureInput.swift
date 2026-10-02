import AppKit
import Carbon

/// Process-wide secure-keyboard-input state (Carbon's `EnableSecureEventInput`)
/// — blocks other processes' event taps/monitors from observing keystrokes
/// while a terminal is at a password prompt (`macos-auto-secure-input`, OSC
/// 133 password detection). The OS flag is global and STATEFUL: every enable
/// must balance with exactly one disable, and it must be yielded while AgentPad
/// is inactive (holding it would degrade other apps while they're frontmost).
/// Surfaces register while their PTY shows a password prompt AND they hold
/// keyboard focus — mirroring ghostty.app's SecureInput scoped model.
///
/// One toggle site: `desired` folds app-activity in, and both activation
/// notifications (fired AFTER `NSApp.isActive` flips — they're "did"
/// notifications) just re-run `apply()`. `enabled` alone gates the Carbon
/// calls, so balance holds no matter which input changed.
@MainActor
final class AgentPadSecureInput {
    static let shared = AgentPadSecureInput()

    /// Surfaces currently at a focused password prompt.
    private var holders: Set<ObjectIdentifier> = []
    /// True only after a successful EnableSecureEventInput.
    private(set) var enabled = false

    private var desired: Bool { NSApp.isActive && !holders.isEmpty }

    private init() {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AgentPadSecureInput.shared.apply() }
            }
        }
    }

    func setHolding(_ id: ObjectIdentifier, _ holding: Bool) {
        if holding { holders.insert(id) } else { holders.remove(id) }
        apply()
    }

    private func apply() {
        guard enabled != desired else { return }
        let err = enabled ? DisableSecureEventInput() : EnableSecureEventInput()
        if err == noErr {
            enabled = desired
        } else {
            NSLog("agentpad: secure input \(desired ? "enable" : "disable") failed (\(err))")
        }
    }
}
