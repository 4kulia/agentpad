import Darwin
import Foundation
import XCTest
@testable import AgentPadKit

/// A fixture-only child survives its leader, then leaves the original group.
/// Every signal is checked against the captured PID/start-time identity.
enum NativeTeamChildFixture {
    @MainActor static func make(in directory: URL) throws -> URL {
        let source = directory.appendingPathComponent("recovery-child.c")
        let binary = directory.appendingPathComponent("recovery-child")
        try #"""
        #include <stdio.h>
        #include <stdlib.h>
        #include <unistd.h>
        #include <signal.h>
        #include <sys/sysctl.h>
        static void mark(const char *name, int value) {
            FILE *f = fopen(name, "w");
            if (!f) _exit(2);
            fprintf(f, "%d", value); fclose(f);
        }
        int main(void) {
            alarm(30);
            while (access("fork", F_OK)) usleep(10000);
            pid_t child = fork();
            if (child < 0) return 3;
            if (child > 0) return 0;
            alarm(30);
            struct kinfo_proc info = {0};
            size_t size = sizeof(info);
            int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
            if (sysctl(mib, 4, &info, &size, NULL, 0)) return 5;
            FILE *record = fopen("child-pid", "w");
            if (!record) return 6;
            unsigned long long start = (unsigned long long)info.kp_proc.p_starttime.tv_sec * 1000000
                + info.kp_proc.p_starttime.tv_usec;
            fprintf(record, "%d %llu", getpid(), start); fclose(record);
            while (access("detach", F_OK)) usleep(10000);
            if (setsid() < 0) return 4;
            mark("detached", getpid());
            for (;;) pause();
        }
        """#.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", binary.path]
        try compiler.run(); compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return binary
    }

    static func child(in directory: URL) -> ProcessIdentity? {
        guard let value = try? String(contentsOf: directory.appendingPathComponent("child-pid"), encoding: .utf8),
              value.split(separator: " ").count == 2 else { return nil }
        let fields = value.split(separator: " ")
        guard let pid = pid_t(fields[0]), pid > 1, let start = UInt64(fields[1]) else { return nil }
        return ProcessIdentity(pid: pid, startTime: start)
    }

    @discardableResult static func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return condition()
    }

    static func stop(_ child: ProcessIdentity) {
        if TeamProcesses.liveness(child) == .alive { Darwin.kill(child.pid, SIGKILL) }
        XCTAssertTrue(waitUntil { TeamProcesses.liveness(child) == .gone })
    }
}
