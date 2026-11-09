import Foundation

/// A separate W09 run exercises the same fixtures at narrow feed/thread widths.
/// The ordinary W03/W05/W06/W07 gates and their frozen inputs stay unchanged.
enum ChatNativeParityCaptureWidths {
    static var narrow: Bool {
        ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_W09_NARROW"] == "1"
    }

    static func rendered(_ reference: CGFloat) -> CGFloat {
        guard narrow else { return reference }
        return reference == 760 ? 320 : reference == 420 ? 260 : reference
    }

    static func reference(_ rendered: CGFloat) -> CGFloat {
        guard narrow else { return rendered }
        return rendered == 320 ? 760 : rendered == 260 ? 420 : rendered
    }

    static var standard: [CGFloat] { [760, 420].map(rendered) }
    static func inThread(_ width: CGFloat) -> Bool { reference(width) == 420 }
}
