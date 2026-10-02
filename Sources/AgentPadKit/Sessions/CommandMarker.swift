import Foundation

/// Private terminal-title marker the shell's preexec hook emits carrying the
/// command line it just accepted. Like `RemoteLoginMarker` it rides the
/// terminal byte stream (OSC 2) rather than AgentPad's unix socket, which matters
/// twice here:
///
///   * cost — preexec runs before EVERY command, so a `agentpad-hook` spawn there
///     sits on the critical path between the user's Return and the command
///     actually starting (measured ~8ms of fork + Swift runtime startup per
///     command). A `printf` costs nothing.
///   * ordering — the exit status arrives as OSC 133;D on this same stream, so
///     the text is guaranteed to land before the result it labels. A socket
///     and the byte stream are two transports with no ordering between them,
///     which let a fast command's result render against stale text.
///
/// Wire title shape:
///   agentpad-command:<command line>
///
/// Delivered via OSC 2 and intercepted before it becomes a visible tab title.
enum CommandMarker {
    /// `internal` so the shell hooks interpolate the same constant the parse
    /// reads — one source of truth for the wire prefix.
    static let titlePrefix = "agentpad-command:"

    /// Interpolated into the shell hooks as their truncation length, so both
    /// ends of the wire agree. Every consumer truncates by CHARACTER while
    /// libghostty's OSC buffer caps BYTES (2048), so the budget assumes the
    /// 4-byte worst case: 480 × 4 + the prefix + OSC framing ≈ 1950 < 2048.
    /// An overflowing marker isn't clipped — the whole OSC is dropped and
    /// the command records no text at all, so headroom matters more than
    /// the extra characters.
    static let maxLength = 480

    /// Returns the reported command line, or nil when `raw` isn't a command
    /// marker (or carries nothing after sanitising).
    static func parseTitle(_ raw: String) -> String? {
        guard let title = normalizedTitle(raw),
              title.hasPrefix(titlePrefix)
        else { return nil }

        return sanitize(String(title.dropFirst(titlePrefix.count)))
    }

    /// The shell already flattens and truncates before emitting; this is not
    /// redundant. The byte stream is not a trust boundary — any program can
    /// print this escape sequence — so re-apply both before the value reaches
    /// SwiftUI. Controls become spaces rather than being dropped so words
    /// can't silently fuse into a different-looking command.
    private static func sanitize(_ raw: String) -> String? {
        let flattened = String(raw.unicodeScalars.map { scalar -> Character in
            // C0 controls (0x00-0x1F) + DEL (0x7F)
            if scalar.value < 0x20 || scalar.value == 0x7F { return " " }
            return Character(scalar)
        })
        let trimmed = flattened.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Truncate by `Character` so CJK stays whole.
        return String(trimmed.prefix(maxLength))
    }
}
