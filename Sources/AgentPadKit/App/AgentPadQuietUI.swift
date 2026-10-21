#if DEBUG
import AppKit
import Darwin

/// Mandatory containment for native checks and screenshots. This changes only
/// test-process boundaries; focus assertions still inspect firstResponder.
@MainActor
public enum AgentPadQuietUI {
    public enum Failure: Error, CustomStringConvertible {
        case violation(String)
        public var description: String {
            switch self { case .violation(let message): message }
        }
    }

    // The app has no link dependency on test support. DEBUG launchers inject
    // it before main so its +load installs containment before any AppKit use.
    private static func symbol<T>(_ name: String, as type: T.Type) -> T {
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            fputs("QUIET FAIL: missing injected test support (\(name)); use the quiet test launcher\n", stderr)
            exit(1)
        }
        return unsafeBitCast(address, to: type)
    }

    public static var isEnabled: Bool {
        symbol("APQuietIsEnabled", as: (@convention(c) () -> ObjCBool).self)().boolValue
    }
    public static func start() {
        guard isEnabled else {
            fputs("QUIET FAIL: injected test support did not enable containment before main\n", stderr)
            exit(1)
        }
        symbol("APQuietStart", as: (@convention(c) () -> Void).self)()
    }
    public static func select(_ window: NSWindow) {
        symbol("APQuietSelectWindow", as: (@convention(c) (NSWindow) -> Void).self)(window)
    }
    public static func send(_ event: NSEvent, to window: NSWindow) {
        symbol("APQuietSendEvent", as: (@convention(c) (NSEvent, NSWindow) -> Void).self)(event, window)
    }
    public static func assertQuiet() throws {
        let failure = symbol("APQuietFailure", as: (@convention(c) () -> Unmanaged<NSString>?).self)()
        if let failure { throw Failure.violation(failure.takeUnretainedValue() as String) }
    }
    public static func finish() throws {
        let summary = symbol("APQuietFinish", as: (@convention(c) () -> Unmanaged<NSString>).self)()
        print(summary.takeUnretainedValue())
        try assertQuiet()
    }
}
#endif
