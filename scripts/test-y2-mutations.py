#!/usr/bin/env python3
"""Y2 rule rollbacks. Run alone (no concurrent Swift build), from this checkout.

Each mutation changes production code, must compile and fail an assertion, and
is restored in finally. Logs are outside the checkout. No real Claude, server,
user settings, keychain, or process-name signals are used.
"""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TEAM = "Sources/AgentPadKit/AgentPad/Team/"
PREFLIGHT = TEAM + "ClaudeVersionPreflight.swift"
RUNNER = TEAM + "TeamRunner.swift"
LAUNCHER = TEAM + "TeamLauncher.swift"
OWNER = "Sources/AgentPadKit/AgentPad/Chat/ChatOwnerSide.swift"
V = "TeamRunnerVersionTests."
L = "TeamVersionLauncherTests."

# (name, source, old, replacement, focused test filter)
CASES = [
    ("granted-folders-before-wait", RUNNER, "try Self.validateGrantedFolders(request)\n        let ready =", "let ready =", V + "testGrantedFoldersMustAlreadyBeCanonicalBeforePreflight"),
    ("granted-folders-after-wait", RUNNER, "try Self.validateGrantedFolders(request)\n        let arguments =", "let arguments =", V + "testGrantedFoldersAreRecheckedAfter"),
    ("executor-active-after-wait", RUNNER, 'onActivity(request.resume ? "Продолжает выполнение" : "Выполняет запрос")', '_ = request.resume', "testVersionApprovalReplacesWaitingActivityInUIAndMCPForSilentExecutor"),
    ("stop-live-finish-debt", OWNER,
     'guard TeamLauncher.finish(run, .stoppedLocally, reason: "stopped_by_owner", journal: journal, facts: service, at: Date()) else { return .retry }',
     '_ = TeamLauncher.finish(run, .stoppedLocally, reason: "stopped_by_owner", journal: journal, facts: service, at: Date())',
     "testStopRetriesFactInsertFailureAfterSavedConfirmationWithoutAnotherEvent"),
    ("stop-saved-finish-debt", OWNER,
     'guard TeamLauncher.finish(now, .stoppedLocally, reason: "stopped_by_owner", journal: journal, facts: service, at: Date()) else { return .retry }',
     '_ = TeamLauncher.finish(now, .stoppedLocally, reason: "stopped_by_owner", journal: journal, facts: service, at: Date())',
     "testStopRetriesFactInsertFailureAfterSavedConfirmationWithoutAnotherEvent"),
    ("recover-outcome-debt", OWNER,
     'return recovered.processesGoneAt != nil ? .retry : .later', 'return .done',
     "testRecoverRetriesOutcomeAndFactDebtAfterSavedConfirmation"),
    ("recover-fact-debt", OWNER,
     'return recovered.processesGoneAt != nil ? .retry : .later\n            }',
     'return recovered.processesGoneAt != nil ? .retry : .later\n            }\n            return .done',
     "testRecoverRetriesOutcomeAndFactDebtAfterSavedConfirmation"),
    ("recover-unconfirmed-outcome-debt", OWNER,
     'run.stopConfirmedAt == nil, run.processesGoneAt == nil {', 'run.stopConfirmedAt == nil {',
     "testRecoverRetriesOutcomeAndStopFailedDebtAfterProcessesGone"),
    ("matrix-exact-version", RUNNER, "version == probeVersion,", "true,", V + "testMatrixAndNativeCache"),
    ("matrix-profile", RUNNER, "profile == .read || profile == .editFiles", "true", V + "testMatrixAndNativeCache"),
    ("matrix-configuration", RUNNER, "revision == configuration,", "true,", V + "testMatrixAndNativeCache"),
    ("selection-before-path", RUNNER, "explicit ?? configured ?? locate()", "locate() ?? explicit ?? configured", V + "testMissingUnavailableAndWrappersRefuseBeforeVersion"),
    ("native-only", PREFLIGHT, "].contains(magic) else", "].contains(magic) || true else", V + "testMissingUnavailableAndWrappersRefuseBeforeVersion"),
    ("version-final-path", PREFLIGHT, "path: executable.file.resolvedPath, arguments:", "path: executable.selectedPath, arguments:", V + "testSelectedNameFinalPathAndSwitchAfterLastCheck"),
    ("environment-final-path", PREFLIGHT, "environment(claudePath: executable.file.resolvedPath,", "environment(claudePath: executable.selectedPath,", V + "testSelectedNameFinalPathAndSwitchAfterLastCheck"),
    ("executor-final-path", RUNNER, "let claude = ready.executable.file.resolvedPath", "let claude = ready.executable.selectedPath", V + "testSelectedNameFinalPathAndSwitchAfterLastCheck"),
    ("only-version-argument", PREFLIGHT, 'arguments: ["--version"]', 'arguments: ["--version", "-p"]', V + "testMatrixAndNativeCache"),
    ("version-exit-status", PREFLIGHT, "exitCode == 0, !overflow,", "true, !overflow,", V + "testVersionFormatLimitsAndFailureIsNotCached"),
    ("version-byte-limit", PREFLIGHT, "4096", "65536", V + "testVersionFormatLimitsAndFailureIsNotCached"),
    ("version-time-limit", PREFLIGHT, "timeout: .seconds(3)", "timeout: .seconds(10)", V + "testVersionFormatLimitsAndFailureIsNotCached"),
    ("cache-file-identity", PREFLIGHT, "hit.0 == executable.file", "true", V + "testCacheInvalidationIncludesIdentitySizeNanosecondsAndSymlinkTarget"),
    ("verify-detected-changes", PREFLIGHT, "guard (try? inspect(executable.selectedPath)) == executable else", "guard true else", V + "testDetectedReplacementAtEveryCheckRefuses"),
    ("unknown-version-needs-owner", PREFLIGHT, "if contains(grant) { return }", "if true { return }", V + "testUnknownVersionWaitsThenRunsOnceAndRemainsUntested"),
    ("refusal-is-final", PREFLIGHT, 'guard answer else { throw TeamRunnerError.didNotStart("version_not_allowed") }', 'guard true else { throw TeamRunnerError.didNotStart("version_not_allowed") }', L + "testWaitAndDeclineSpendD9OnlyOnce"),
    ("grant-persisted", PREFLIGHT, "defaults?.set(data, forKey: Self.settingsKey)", "_ = data", V + "testGrantBindingAndPersistence"),
    ("permission-not-evidence", PREFLIGHT, 'basis = "Непроверенная версия, разрешена владельцем"', 'basis = "Граница без Bash проверена"', V + "testUnknownVersionWaitsThenRunsOnceAndRemainsUntested"),
    ("wait-activity", PREFLIGHT, 'onActivity("Ожидает разрешения владельца на версию Claude Code \\(grant.version)")', 'onActivity("waiting")', V + "testUnknownVersionWaitsThenRunsOnceAndRemainsUntested"),
    ("cancellation-before-executor", PREFLIGHT, "if Task.isCancelled { throw TeamRunnerError.cancelledBeforeExecutor }", "if false { throw TeamRunnerError.cancelledBeforeExecutor }", V + "testStopDuringVersionAndOwnerWaitNeverCreatesExecutor"),
    ("cleanup-must-be-confirmed", PREFLIGHT, "guard cleanup == .stopped else", "guard true else", L + "testCleanupUnconfirmedFromRealVersionProcess"),
    ("service-identity-recorded", PREFLIGHT, "try request.onPreflightProcess?(spawned.identity)", "try request.onPreflightProcess?(nil)", L + "testConfirmedPreflightStopUnblocksEvenWithoutNetwork"),
    ("service-identity-cleared", PREFLIGHT, "do { try request.onPreflightProcess?(nil) } catch", "do { _ = request.onPreflightProcess } catch", L + "testConfirmedPreflightStopUnblocksEvenWithoutNetwork"),
    ("confirmed-preflight-unblocks", LAUNCHER, "if case .failure(let error) = result, error as? TeamRunnerError == .cancelledBeforeExecutor { return .stopped }", "if case .failure(let error) = result, error as? TeamRunnerError == .cancelledBeforeExecutor { return .unknown(\"no PID\") }", L + "testConfirmedPreflightStopUnblocksEvenWithoutNetwork"),
    ("unconfirmed-preflight-stays-open", LAUNCHER, "if case .failure(let error) = outcome,\n           case .preflightCleanupUnconfirmed", "if case .failure(let error) = outcome, false,\n           case .preflightCleanupUnconfirmed", L + "testUnconfirmedServiceCleanupPersistsAndReportsStopFailed"),
    ("d9-revalidated-after-wait", LAUNCHER, "try self.validateWaitingSegment(params, row: row)", "_ = self", L + "testExpiryAndChangedTermsDuringWaitExcludeLateConsent"),
    ("continuation-failure-fact", LAUNCHER, "if params.segment != nil {\n                    ended(row, .failed, reason: notStarted", "if params.segment != nil {\n                    ended(row, .didNotStart, reason: notStarted", L + "testFolderContinuationWaitAcceptDeclineAndTechnicalFailure"),
    ("recovery-service-identity", LAUNCHER, "if let pid = run.preflightPID, pid > 1, let start = run.preflightStartedAt", "if let pid = run.preflightPID, false, pid > 1, let start = run.preflightStartedAt", L + "testUnconfirmedServiceCleanupPersistsAndReportsStopFailed"),
    ("starting-ui-activity", TEAM + "TeamCallsSidebar.swift", 'case "starting": return activity ?? "starting"', 'case "starting": return "starting"', "testY2ActivityInStartingIsPendingAndHasNoPaths"),
    ("cli-pending", "Sources/AgentPadHookKit/TeamCLI.swift", 'call.state == "done" ? 0 : call.final ? 1 : 2', 'call.state == "done" ? 0 : 1', "testVersionWaitRemainsPendingWithOrWithoutActivity"),
    ("mcp-pending", "Sources/AgentPadHookKit/TeamMCPServer.swift", '["status": "pending", "call_id": call.id]', '["status": "ended", "call_id": call.id]', "testVersionWaitRemainsPendingWithOrWithoutActivity"),
    ("mcp-wait-explanation", "Sources/AgentPadHookKit/TeamMCPServer.swift", '\\(call.activity.map { " — \\($0)" } ?? "")', '', "testVersionWaitRemainsPendingWithOrWithoutActivity"),
    ("service-failure-wire-reason", "Sources/AgentPadKit/AgentPad/Chat/ChatOwnerSide.swift", '["processes_alive", "processes_unknown", "preflight_cleanup_unconfirmed"]', '["processes_alive", "processes_unknown"]', "testY2ServiceCleanupFailureReasonSurvivesRecoveryAndStopRetry"),
    ("service-reason-after-manual-recovery", "Sources/AgentPadKit/AgentPad/Chat/ChatOwnerSide.swift", 'run.preflightPID != nil ? "preflight_cleanup_unconfirmed" : reason', 'reason', "testY2ServiceCleanupFailureReasonSurvivesRecoveryAndStopRetry"),
    ("late-server-stop", LAUNCHER, "guard requestCanExecute(row.requestId) else", "guard true else", L + "testExpiryAndChangedTermsDuringWaitExcludeLateConsent"),
    ("persistent-consent-explained", PREFLIGHT, "Разрешение сохранится и будет действовать для следующих запросов этого профиля, пока не сменится версия или файл.", "Разрешение только на этот запрос.", V + "testUnknownVersionWaitsThenRunsOnceAndRemainsUntested"),
    ("one-consent-for-other-waiters", PREFLIGHT, "if contains(grant) { return }\n                if ContinuousClock", "if false { return }\n                if ContinuousClock", V + "testOneDecisionAlsoReleasesOtherWaitersForTheSameGrant"),
    ("unknown-profile-refused", TEAM + "TeamApprovals.swift", "guard let profile = TeamAccessProfile(rawValue: inputs.access) else", "guard let profile = Optional(TeamAccessProfile.read) else", L + "testUnknownProfileIsAParameterErrorAndNeverBecomesRead"),
]

# Roll back each binding dimension separately, using the same equality for
# lookup as the synthesized Hashable normally supplies. No test is mutated.
FIELDS = ["version", "profile", "configuration", "file.resolvedPath", "file.device", "file.inode", "file.size", "file.modifiedSeconds", "file.modifiedNanoseconds"]
for omitted in FIELDS:
    predicate = " && ".join(f"$0.{field} == grant.{field}" for field in FIELDS if field != omitted)
    CASES.append(("grant-binding-" + omitted, PREFLIGHT, "grants.contains(grant)", "grants.contains { " + predicate + " }", V + "testGrantBindingAndPersistence"))


def stop_invocation(process):
    # SwiftPM starts xctest in a separate process group. Killing only the
    # swift-test group leaves a timed-out test alive, holding its memory.
    # Collect this invocation's descendants before terminating their parent;
    # never select targets by command name or read their arguments.
    table = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
    parents = {int(pid): int(parent) for pid, parent in (line.split() for line in table.splitlines())}
    targets = [process.pid]
    for parent in targets:
        targets.extend(pid for pid, ppid in parents.items() if ppid == parent and pid not in targets)
    for pid in reversed(targets):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", help="comma-separated mutation names")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    folder = args.output or Path(tempfile.mkdtemp(prefix="agentpad-y2-mutations-"))
    folder.mkdir(parents=True, exist_ok=True)
    selected = set(args.only.split(",")) if args.only else None
    results = []
    for name, file, old, new, test in CASES:
        if selected and name not in selected:
            continue
        path = ROOT / file
        original = path.read_text()
        if old not in original:
            raise RuntimeError(f"Mutation anchor missing: {name}")
        log = folder / (name + ".log")
        try:
            path.write_text(original.replace(old, new))
            with log.open("w") as output:
                process = subprocess.Popen(["swift", "test", "-j", "1", "--filter", test], cwd=ROOT,
                                           stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    code = process.wait(timeout=180)
                except subprocess.TimeoutExpired:
                    stop_invocation(process)
                    code = -1
                except BaseException:
                    stop_invocation(process)
                    raise
        finally:
            path.write_text(original)
        text = log.read_text()
        failures = len(re.findall(r"error: -\[.*?\]", text))
        caught = code != 0 and failures > 0 and "Build complete!" in text
        result = dict(name=name, test=test, caught=caught, failures=failures, exit=code, log=str(log))
        results.append(result)
        (folder / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
        print(json.dumps(result), flush=True)
        if not caught:
            raise SystemExit(f"Rollback was not caught by an assertion: {name}; source restored")
    print(f"All {len(results)} rollbacks caught; sources restored. {folder}", flush=True)


if __name__ == "__main__":
    main()
