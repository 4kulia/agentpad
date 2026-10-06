import Darwin
import Foundation
import Security

/// Trust the running executable's signature, never its name or installation path.
/// Permission also requires live PID/start, tab/TTY ancestry and no team run.
enum ChatClaudeProcess {
    typealias SignatureVerifier = (Int32) -> Bool

    /// A signature result may only be reused for this process lifetime/image.
    struct SignatureKey: Hashable, Sendable {
        let pid: Int32
        let startedAtUs: UInt64
        let image: ImageIdentity
    }

    struct ImageIdentity: Hashable, Sendable {
        let path: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let auditToken: Data?
    }

    /// Only executable metadata, never argv, environment or profile contents.
    /// The audit token additionally distinguishes exec in the same PID when
    /// available; stat also rejects replacement/in-place changes at the path.
    static func imageIdentity(of pid: Int32) -> ImageIdentity? {
        guard let path = executablePath(of: pid) else { return nil }
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return ImageIdentity(path: path, device: info.st_dev, inode: info.st_ino, size: info.st_size,
                             modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                             changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec),
                             auditToken: auditToken(of: pid))
    }

    // Fail closed if Anthropic changes its signing identity. The Apple anchor
    // prevents a self-signed certificate from supplying the expected team OU.
    static let signingRequirement = #"anchor apple generic and identifier "com.anthropic.claude-code" and certificate leaf[subject.OU] = "Q6L2SF6YDW""#

    static func hasTrustedSignature(_ pid: Int32) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(signingRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return hasValidSignature(pid, requirement: requirement, auditToken: auditToken(of: pid))
    }

    /// Separate requirement argument lets tests exercise real Security APIs with
    /// their own ad-hoc fixtures, without any Anthropic signing material.
    static func hasValidSignature(_ pid: Int32, requirement: SecRequirement, auditToken: Data?,
                                  executablePath: (Int32) -> String? = executablePath) -> Bool {
        guard pid > 0 else { return false }
        var attributes: [CFString: Any] = [kSecGuestAttributePid: pid]
        if let auditToken { attributes[kSecGuestAttributeAudit] = auditToken }
        func liveCode() -> SecCode? {
            var code: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess,
                  let code,
                  SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
            return code
        }
        guard let code = liveCode(), let image = codeIdentity(code) else { return false }
        if auditToken == nil {
            // proc_pidpath alone is not evidence: a replacement at that path
            // must also match the validated kernel image's CodeDirectory.
            guard let path = executablePath(pid) else { return false }
            var disk: SecStaticCode?
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &disk) == errSecSuccess,
                  let disk, SecStaticCodeCheckValidity(disk, [], requirement) == errSecSuccess,
                  codeIdentity(disk) == image else { return false }
        }
        // Obtain a fresh guest: an earlier SecCode can cache its disk identity.
        // CheckValidity binds the signature to the kernel image (not just disk).
        // A supplied audit token that no longer matches never falls back to PID.
        guard let current = liveCode() else { return false }
        return codeIdentity(current) == image
    }

    private static func codeIdentity(_ code: SecCode) -> Data? {
        var disk: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &disk) == errSecSuccess, let disk else { return nil }
        return codeIdentity(disk)
    }

    private static func codeIdentity(_ code: SecStaticCode) -> Data? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let image = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              !image.isEmpty else { return nil }
        return image
    }

    /// A socket audit token belongs to the MCP child, not necessarily Claude.
    /// Ask the kernel for this ancestor's token without requesting task control.
    static func auditToken(of pid: Int32) -> Data? {
        guard pid > 0 else { return nil }
        var port: mach_port_name_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &port) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, port) }
        var token = audit_token_t()
        let expected = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
        var count = expected
        let result = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(expected)) {
                task_info(port, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count == expected else { return nil }
        return withUnsafeBytes(of: token) { Data($0) }
    }

    /// Kernel executable path only. Never read argv, environment or profiles.
    static func executablePath(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE (a C macro not imported by Swift).
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
