import Darwin
import Foundation

/// Reads the launch-time environment variables of another process via
/// macOS's `KERN_PROCARGS2` sysctl. This is a fallback before the prompt
/// hook reports live shell state; `nvm use` / `activate` changes are driven
/// by the hook path, not by this snapshot.
///
/// Buffer layout returned by the kernel:
///   [Int32 argc]
///   [exec_path\0]
///   [argv0\0][argv1\0]...[argv(argc-1)\0]
///   [KEY=VALUE\0][KEY=VALUE\0]...[empty\0]
///
/// Permissions: same UID can always read its own children — no entitlement
/// needed. Returns nil on cross-UID, dead PID, or kernel rejection.
enum ProcessEnvReader {
    static func readEnv(pid: pid_t) -> [String: String]? {
        // Kernel-imposed cap on argc + env total size.
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        var argMaxName: [Int32] = [CTL_KERN, KERN_ARGMAX]
        if sysctl(&argMaxName, 2, &argMax, &argMaxSize, nil, 0) != 0 || argMax <= 0 {
            argMax = 1024 * 1024
        }

        var buffer = [CChar](repeating: 0, count: Int(argMax))
        var bufferSize = Int(argMax)
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        if sysctl(&name, 3, &buffer, &bufferSize, nil, 0) != 0 {
            return nil
        }
        // macOS 14+ truncates the env block here for non-privileged readers
        // (the buffer comes back with just argc + argv). The prompt hook
        // path is what actually populates the status bar; this returns
        // whatever it can for the cold-start window.
        return parse(buffer, length: bufferSize)
    }

    /// Walks the procargs2 buffer past argc, exec_path, and argv to land on
    /// the env block, then tokenizes `KEY=VALUE` entries until the trailing
    /// null run.
    static func parse(_ buffer: [CChar], length: Int) -> [String: String] {
        guard length >= MemoryLayout<Int32>.size else { return [:] }
        let argc: Int32 = buffer.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        }
        var offset = MemoryLayout<Int32>.size
        // exec_path (NUL-terminated)
        while offset < length, buffer[offset] != 0 { offset += 1 }
        // alignment-pad nulls between exec_path and argv[0]
        while offset < length, buffer[offset] == 0 { offset += 1 }
        // skip argc argv strings, each ending in a single null
        var seen = 0
        while seen < Int(argc), offset < length {
            while offset < length, buffer[offset] != 0 { offset += 1 }
            offset += 1
            seen += 1
        }
        // Some kernels emit NUL alignment padding between argv and env;
        // Apple's reference parser explicitly skips it. Without this hop
        // the env loop's `offset == start` guard fires immediately and we
        // miss every KEY=VALUE entry on cold-start.
        while offset < length, buffer[offset] == 0 { offset += 1 }
        // env block — KEY=VALUE strings until empty entry
        var env: [String: String] = [:]
        while offset < length {
            let start = offset
            while offset < length, buffer[offset] != 0 { offset += 1 }
            if offset == start { break }
            let bytes = (start..<offset).map { UInt8(bitPattern: buffer[$0]) }
            if let entry = String(bytes: bytes, encoding: .utf8),
               let eq = entry.firstIndex(of: "=") {
                env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            }
            offset += 1
        }
        return env
    }
}
