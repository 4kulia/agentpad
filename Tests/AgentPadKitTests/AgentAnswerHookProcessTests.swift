import AgentPadHookKit
import XCTest
@testable import AgentPadKit

/// Real kernel parent/TTY/group/image reads and socket peer authentication.
/// Only Anthropic's signature is substituted; no real Claude/profile is used.
@MainActor
final class AgentAnswerHookProcessTests: XCTestCase {
    func testHookThroughShellAndForegroundLaunchWrapperWithRealProcesses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("answer-process-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fixture.py"), owner = root.appendingPathComponent("owner.pid")
        let path = NSTemporaryDirectory() + "answer-pty-\(UUID().uuidString.prefix(8)).sock"
        let store = makeTestStore(claudeProjectsRoot: root)
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession)
        tab.agent = .claudeCode
        let id = UUID().uuidString.lowercased()
        var inspector = AgentAnswerProvenance.Inspector()
        inspector.signed = { pid in
            XCTAssertFalse(Thread.isMainThread)
            return (try? String(contentsOf: owner, encoding: .utf8)) == String(pid)
        }
        let verified = expectation(description: "real shell hook bound to its foreground wrapper")
        let server = HookServer(socketPath: path, answerInspector: inspector) { message in
            guard case .conversationId(let journal, let surface, let provenance) = message else { return }
            defer { verified.fulfill() }
            XCTAssertEqual(surface, tab.id)
            XCTAssertEqual(journal, id)
            guard let provenance else { return XCTFail("a normal shell hook must be verified") }
            let wrapper = provenance.snapshots.first { $0.process.pid == provenance.process.parent }
            XCTAssertNotNil(wrapper)
            XCTAssertEqual(wrapper?.name, "bash")
            XCTAssertEqual(wrapper?.isForeground, true)
            XCTAssertNotEqual(wrapper?.process.pid, provenance.process.pid)
            XCTAssertTrue(provenance.isCurrent())
            (tab.engine as? TestEngine)?.foregroundPid = wrapper?.process.pid
            AgentAnswerSource.recordHook(conversation: journal, session: tab, provenance: provenance)
            XCTAssertEqual(tab.answerBinding?.conversation, id)
            XCTAssertNil(AgentAnswerSource.problem(tab))
        }
        server.start()
        defer { server.stop() }
        // '; :' keeps both shells alive instead of optimizing them into exec.
        // The owner waits after ACK so UI revalidation sees a live session.
        try #"""
        import json, os, shlex, socket, subprocess, sys, time
        mode, script, owner, path, surface, journal = sys.argv[1:]
        def command(mode):
            return shlex.join([sys.executable, script, mode, script, owner, path, surface, journal]) + '; :'
        if mode == 'launch':
            pid, terminal = os.forkpty()
            if pid == 0:
                os.execl('/bin/bash', 'bash', '--noprofile', '--norc', '-c', command('owner'))
            _, status = os.waitpid(pid, 0)
            os.close(terminal)
            sys.exit(os.waitstatus_to_exitcode(status))
        elif mode == 'owner':
            with open(owner, 'w') as f:
                f.write(str(os.getpid()))
            subprocess.run(['/bin/sh', '-c', command('hook')], check=True, timeout=5)
            time.sleep(0.5)
        else:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(4)
                s.connect(path)
                payload = dict(kind='conversationId', surface=surface, conversationId=journal, claudeParentPID=str(os.getppid()))
                s.sendall(json.dumps(payload).encode() + b'\n')
                s.shutdown(socket.SHUT_WR)
                assert s.recv(1) == b'\n'
                time.sleep(0.5)
        """#.write(to: script, atomically: true, encoding: .utf8)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [script.path, "launch", script.path, owner.path, path, tab.id.uuidString, id]
        child.environment = ["PATH": "/usr/bin:/bin"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        await fulfillment(of: [verified], timeout: 6)
        await Task.detached { child.waitUntilExit() }.value
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertNotNil(tab.answerBinding)
        XCTAssertEqual(AgentAnswerSource.problem(tab), .changed, "exiting the actual owner revokes export")
    }
}
