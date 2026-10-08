import AgentPadHookKit
import Darwin
import Security
import XCTest
@testable import AgentPadKit

@MainActor
final class AgentAnswerResumedProcessTests: XCTestCase {
    func testLoginZshProductionWrapperVersionSymlinkResumeAndDetachedHook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("answer-resume-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = root.appendingPathComponent("Library/Application Support/agentpad/bin/claude")
        let binary = root.appendingPathComponent(".local/share/claude/versions/2.1.292")
        let link = root.appendingPathComponent(".local/bin/claude")
        for file in [wrapper, binary, link] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try AgentPadShellIntegration.claudeWrapperScript.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let source = root.appendingPathComponent("owner.c")
        try #"""
        #include <unistd.h>
        #include <sys/wait.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        int main(int argc, char **argv) {
            alarm(15);
            if (argc != 3 || strcmp(argv[1], "--resume") || strcmp(argv[2], getenv("FIXTURE_JOURNAL"))) {
                fputs("fixture: missing --resume argument\n", stderr); return 10;
            }
            // The real AgentPad bash shim remains the foreground group leader.
            if (getpgrp() != getppid() || tcgetpgrp(0) != getppid()) {
                fprintf(stderr, "fixture: parent=%d group=%d foreground=%d\n", getppid(), getpgrp(), tcgetpgrp(0)); return 11;
            }
            pid_t child = fork();
            if (child == 0) {
                // Claude 2.1.292 command hooks use detached=true on macOS.
                if (setsid() < 0) _exit(12);
                execl("/bin/sh", "sh", "-c", getenv("FIXTURE_HOOK_COMMAND"), (char *)0);
                _exit(13);
            }
            int status;
            if (child < 0 || waitpid(child, &status, 0) < 0) return 14;
            while (access(getenv("FIXTURE_RELEASE"), F_OK)) usleep(1000);
            return WIFEXITED(status) ? WEXITSTATUS(status) : 15;
        }
        """#.write(to: source, atomically: true, encoding: .utf8)
        try run("/usr/bin/clang", [source.path, "-o", binary.path])
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "org.agentpad.answer-fixture", binary.path])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        let socket = NSTemporaryDirectory() + "answer-resume-\(UUID().uuidString.prefix(8)).sock"
        let release = root.appendingPathComponent("release")
        let store = makeTestStore(claudeProjectsRoot: root)
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession), journal = UUID().uuidString.lowercased()
        tab.agent = .claudeCode
        tab.conversationId = journal
        tab.resumedConversationId = journal
        var inspector = AgentAnswerProvenance.Inspector()
        // Real Security APIs, using only our ad-hoc fixture requirement.
        inspector.signed = { pid in
            XCTAssertFalse(Thread.isMainThread)
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(#"identifier "org.agentpad.answer-fixture""# as CFString, [], &requirement) == errSecSuccess,
                  let requirement else { return false }
            return ChatClaudeProcess.hasValidSignature(pid, requirement: requirement, auditToken: ChatClaudeProcess.auditToken(of: pid))
        }
        let received = expectation(description: "detached hook from resumed versioned Claude")
        let server = HookServer(socketPath: socket, answerInspector: inspector) { message in
            guard case .conversationId(let id, let surface, let proof, let failure) = message else { return }
            defer { received.fulfill() }
            XCTAssertEqual(id, journal)
            XCTAssertEqual(surface, tab.id)
            XCTAssertNil(failure)
            guard let proof else { return XCTFail("detached hook must retain verified ancestry") }
            let launch = proof.snapshots.first { $0.process.pid == proof.process.parent }
            XCTAssertEqual(launch?.image.path, "/bin/bash")
            XCTAssertEqual(launch?.isForeground, true)
            let shell = proof.snapshots.first { $0.process.pid == launch?.process.parent }
            XCTAssertEqual(shell?.image.path, "/bin/zsh")
            let login = proof.snapshots.first { $0.process.pid == shell?.process.parent }
            XCTAssertEqual(login?.image.path, "/usr/bin/login")
            let image = proof.snapshots.first { $0.process == proof.process }?.image.path
            XCTAssertEqual(image.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }, binary.resolvingSymlinksInPath())
            XCTAssertTrue(proof.snapshots.contains { $0.isShell && $0.process.terminal == nil })
            (tab.engine as? TestEngine)?.foregroundPid = launch?.process.pid
            AgentAnswerSource.recordHook(conversation: id, session: tab, provenance: proof, failure: failure)
            XCTAssertNil(AgentAnswerSource.problem(tab))
        }
        server.start()
        defer { server.stop() }
        let script = root.appendingPathComponent("launcher.py")
        try #"""
        import json, os, pwd, select, shlex, signal, socket, sys, time
        mode, wrapper, surface, journal, path = sys.argv[1:]
        if mode == 'launch':
            # Resolve Directory Services before fork (not fork-safe on macOS).
            user = pwd.getpwuid(os.getuid()).pw_name
            pid, terminal = os.forkpty()
            if pid == 0:
                command = 'PATH=' + shlex.quote(os.environ['PATH']) + ' ' + shlex.join([wrapper, '--resume', journal]) + '; fixture_status=$?; exit $fixture_status'
                os.execl('/usr/bin/login', 'login', '-flpq', user,
                         '/bin/zsh', '-dflim', '-c', command)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                done, status = os.waitpid(pid, os.WNOHANG)
                if done:
                    break
                if select.select([terminal], [], [], 0.02)[0]:
                    try:
                        os.write(2, os.read(terminal, 4096))
                    except OSError:
                        pass
            else:
                os.kill(pid, signal.SIGKILL)
                os.close(terminal)
                sys.exit(16)
            os.close(terminal)
            sys.exit(os.waitstatus_to_exitcode(status))
        else:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(5)
                s.connect(path)
                payload = dict(kind='conversationId', surface=surface, conversationId=journal, claudeParentPID=str(os.getppid()))
                s.sendall(json.dumps(payload).encode() + b'\n')
                s.shutdown(socket.SHUT_WR)
                assert s.recv(1) == b'\n'
            # Keep the detached helpers stable during UI export checks:
            # an exit between kernel and image reads is deliberately refused.
            deadline = time.monotonic() + 10
            while not os.path.exists(os.environ['FIXTURE_RELEASE']) and time.monotonic() < deadline:
                time.sleep(0.01)
            assert os.path.exists(os.environ['FIXTURE_RELEASE'])
        """#.write(to: script, atomically: true, encoding: .utf8)
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let arguments = [script.path, "launch", wrapper.path, tab.id.uuidString, journal, socket]
        let hookCommand = (["/usr/bin/python3", script.path, "hook"] + Array(arguments.dropFirst(2))).map(quoted).joined(separator: " ") + "; fixture_status=$?; exit $fixture_status"
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = arguments
        child.environment = ["PATH": "\(wrapper.deletingLastPathComponent().path):\(link.deletingLastPathComponent().path):/usr/bin:/bin",
                             "HOME": root.path, "ZDOTDIR": root.path, "AGENTPAD_SURFACE_ID": tab.id.uuidString,
                             "FIXTURE_JOURNAL": journal, "FIXTURE_HOOK_COMMAND": hookCommand, "FIXTURE_RELEASE": release.path]
        let log = root.appendingPathComponent("terminal.log")
        try Data().write(to: log)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        child.standardOutput = output
        child.standardError = output
        try child.run()
        defer { try? Data().write(to: release) }
        await fulfillment(of: [received], timeout: 10)
        if tab.answerBinding != nil {
            do {
                let answer = try await AgentAnswerSource.read(session: tab, store: store) { _, id, _ in
                    XCTAssertEqual(id, journal)
                    return "Resumed answer"
                }
                XCTAssertEqual(answer.text, "Resumed answer")
                XCTAssertTrue(answer.isCurrent())
            } catch {
                XCTFail("Resumed answer could not be read: \(error)")
            }
        }
        try Data().write(to: release)
        await Task.detached { child.waitUntilExit() }.value
        XCTAssertEqual(child.terminationStatus, 0, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
        XCTAssertNotNil(tab.answerBinding, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
        XCTAssertEqual(AgentAnswerSource.problem(tab), .changed)
    }

    private func run(_ path: String, _ arguments: [String]) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: path)
        child.arguments = arguments
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
    }
}
