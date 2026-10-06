import CoreFoundation
import Foundation
import os

/// The timer and reporting queue never need the main actor to report a hang.
/// A single outstanding ping bounds queue growth even during a long stall.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()
    private static let logger = Logger(subsystem: "com.4kulia.agentpad", category: "MainThreadWatchdog")

    struct Stall: Sendable {
        let seconds: TimeInterval
        let phase: String
        let checkpoint: String
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "agentpad.main-watchdog", qos: .utility)
    private let threshold: TimeInterval
    private let report: @Sendable (Stall) -> Void
    private var timer: DispatchSourceTimer?
    private var observer: CFRunLoopObserver?
    private var running = false
    private var pingAt: TimeInterval?
    private var busyAt: TimeInterval?
    private var reported = false
    private var phase = "starting"
    private var lastCheckpoint = "application launch"

    init(threshold: TimeInterval = 2, report: @escaping @Sendable (Stall) -> Void = MainThreadWatchdog.reportStall) {
        self.threshold = threshold
        self.report = report
    }

    @MainActor func start() {
        guard lock.withLock({ if running { return false }; running = true; return true }) else { return }
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { [weak self] _, activity in
            self?.runLoop(activity)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: min(0.25, threshold / 4), leeway: .milliseconds(10))
        timer.setEventHandler { @Sendable [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    @MainActor func stop() {
        lock.withLock { running = false; pingAt = nil; busyAt = nil; reported = false }
        timer?.cancel()
        timer = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }

    /// A breadcrumb, not a claim that the last entered method is still running.
    /// No message text, identifiers, tokens, argv or paths supplied by users.
    @MainActor func checkpoint(file: StaticString = #fileID, function: StaticString = #function, line: UInt = #line) {
        lock.withLock { lastCheckpoint = "\(file):\(line) \(function)" }
    }

    private func runLoop(_ activity: CFRunLoopActivity) {
        lock.withLock {
            switch activity {
            case .entry: phase = "entry"
            case .beforeTimers: phase = "before timers"
            case .beforeSources: phase = "before sources"
            case .beforeWaiting: phase = "waiting"
            case .afterWaiting: phase = "after waiting"
            case .exit: phase = "exit"
            default: phase = String(activity.rawValue)
            }
            if activity == .beforeWaiting || activity == .exit { busyAt = nil }
            else if busyAt == nil { busyAt = ProcessInfo.processInfo.systemUptime }
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        var sendPing = false
        let stall: Stall? = lock.withLock {
            guard running else { return nil }
            let since = [pingAt, busyAt].compactMap { $0 }.min()
            if pingAt == nil { pingAt = now; sendPing = true }
            guard let since, now - since > threshold else { reported = false; return nil }
            guard !reported else { return nil }
            reported = true
            return Stall(seconds: now - since, phase: phase, checkpoint: lastCheckpoint)
        }
        if sendPing {
            DispatchQueue.main.async { [weak self] in self?.lock.withLock { self?.pingAt = nil } }
        }
        if let stall { report(stall) }
    }

    private static func reportStall(_ stall: Stall) {
        logger.fault("Main thread unresponsive for \(stall.seconds, privacy: .public)s; run-loop phase=\(stall.phase, privacy: .public); last checkpoint=\(stall.checkpoint, privacy: .public)")
        // Thread.callStackSymbols here would be the WATCHDOG's stack. Ask the
        // OS sampler for the real main thread; never suspend/unwind Swift under
        // its allocator locks. If sampling fails, the breadcrumb above survives.
        guard sampling.admit() else { return }
        sampleQueue.async {
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AgentPad/Hangs", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let old = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.hasPrefix("watchdog-") && $0.pathExtension == "sample" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for file in old.dropLast(4) { try FileManager.default.removeItem(at: file) }
                let file = folder.appendingPathComponent("watchdog-\(Int(Date().timeIntervalSince1970))-\(ProcessInfo.processInfo.processIdentifier).sample")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "1", "10", "-file", file.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                    if process.isRunning { process.terminate() }
                }
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    logger.error("Hang sample saved: \(file.path, privacy: .public)")
                    if let sample = try? String(contentsOf: file, encoding: .utf8) {
                        for frame in mainThreadStack(in: sample) { logger.error("Main stack: \(frame, privacy: .public)") }
                    }
                } else {
                    logger.error("Hang sample failed, status=\(process.terminationStatus); see the last main-thread checkpoint")
                }
            } catch { logger.error("Hang sample could not be saved: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private static let sampleQueue = DispatchQueue(label: "agentpad.hang-sample", qos: .utility)
    private static let sampling = SamplingGate()

    static func mainThreadStack(in sample: String) -> [String] {
        let lines = sample.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.contains("Main Thread") || $0.contains("com.apple.main-thread") }) else { return [] }
        var frames = [lines[start]]
        for line in lines.dropFirst(start + 1) {
            if line.contains("Thread_"), !line.contains("+ ") { break }
            guard !line.isEmpty, frames.count < 32 else { break }
            frames.append(line)
        }
        return frames
    }

    private final class SamplingGate: @unchecked Sendable {
        private let lock = NSLock()
        private var last: TimeInterval = -.infinity
        func admit() -> Bool {
            lock.withLock {
                let now = ProcessInfo.processInfo.systemUptime
                guard now - last >= 60 else { return false }
                last = now
                return true
            }
        }
    }
}
