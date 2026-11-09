import contextlib
import io
import os
import runpy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


RUNNER = runpy.run_path(str(Path(__file__).with_name("test-quiet.py")))
CONTINUITY = [
    "AgentPadKitTests.ChatScrollContinuityTests/" + method
    for method in [
        "testFollowingRevealEditingAndUnreadAcrossBothPanes",
        "testLoadEarlierButtonKeepsVisibleMessage",
        "testNativeMixedHeightScrollContinuity",
        "testOlderInsertionAndHeightChangeKeepScreenOffset",
        "testProjectionAndMarkdownCost",
    ]
]
ALLOWED = "AgentPadKitTests.QuietHarnessTests/testAutomaticBootstrapAndEveryWindowStayInvisible"
BENCHMARK = "AgentPadKitTests.ChatTextMaterializationTests/testProfileNativeTextMaterializationByRowType"
NAMES = [*CONTINUITY, ALLOWED, BENCHMARK]


class QuietSelectionTests(unittest.TestCase):
    def test_native_chat_pipelines_require_an_unlocked_console(self) -> None:
        cases = [
            ("ChatScrollBenchmarkTests", "testFreshProcessMount"),
            ("ChatNativeTextCaptureTests", "testW03MessageAndStructuralReferencePairs"),
            ("ChatNativeScrollTests", "testAccessibilityValueAndActionsCancelBeforeScrollAndDelayedPage"),
            ("ChatNativeLifecycleTests", "testNativeVisitRegistersAndDisposesOnlyItsNotificationPlace"),
            ("ChatNativeAccessibilityTests", "testTimelineKeyLoopAndAccessibilityOrder"),
            ("ChatNativeNavigationTests", "testChannelSearchReturnAndComposerFocusAcrossPaneReplacement"),
            ("ChatNativeMetadataTests", "testWholeMetadataStateAcrossEveryCapabilitySubsetAndReadIndependentUpdates"),
            ("ChatNativeMetadataCaptureTests", "testW07MetadataCapabilitiesAndPinsAgainstActualLegacyThreeCheckGate"),
            ("ChatNativeAgentActionTests", "testLocalPendingCancelRetiresExistingIntentAndRechecksCapabilityAndRights"),
            ("ChatNativeReactorsTests", "testHoverNamesRefreshForDirectoryAndVersionWithoutRefetchLoop"),
            ("ChatNativeParityReviewTests", "testW09ChannelCallersInBothThemesAndWideNarrowPanes"),
            ("ChatNativeParityRowCaptureTests", "testW09ReactionPickerAgainstActualLegacyThreeCheckGate"),
            ("ChatNativeCompositionParityTests", "testMatchingInboxReadClearsOnlyItsMountedBoundaryAndUnrelatedEventsLeaveRowsEqual"),
            ("ChatNativeReactorWindowCaptureTests", "testW09ActualRowOwnedReactorWindowsAgainstLegacyThreeCheckGate"),
            ("ChatNativeIntegrationParityTests", "testActualNativeOverlayClearsNavigationAndNewMessageCount"),
            ("ChatNativeSnapshotParityReviewTests", "testJournalOnlyPublicationCancellationReachesTheMountedNativeRowWithEqualMessages"),
            ("ChatNativeMediaCaptureTests", "testW09ImageGridThresholdsAgainstActualLegacyThreeCheckGate"),
        ]
        for suite, method in cases:
            test = f"AgentPadKitTests.{suite}/{method}"
            self.assertEqual(RUNNER["live_console_tests"]([test], ["--filter", "Chat"]), [test])
            self.assertEqual(RUNNER["live_console_tests"]([test], ["--filter", suite]), [test])

    def setUp(self) -> None:
        self.environment = patch.dict(os.environ)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        os.environ.pop("_SWIFTPM_SKIP_TESTS_LIST", None)

    def test_posix_character_class_blocks_every_continuity_test(self) -> None:
        self.assertEqual(
            RUNNER["live_console_tests"](NAMES, ["--filter", "[[:alpha:]]+ScrollContinuityTests"]),
            CONTINUITY,
        )

    def test_selection_spelling_and_skip_semantics(self) -> None:
        cases = [
            ([], [*CONTINUITY, BENCHMARK]),
            (["--filter", "ChatScrollContinuityTests"], CONTINUITY),
            (["--filter=QuietHarnessTests"], []),
            (["--filter", "testNativeMixedHeightScrollContinuity"], [CONTINUITY[2]]),
            (["--filter", "^AgentPadKitTests[.]ChatScrollContinuityTests/testNativeMixedHeightScrollContinuity$"], [CONTINUITY[2]]),
            (["--filter", "^ChatScrollContinuityTests"], []),
            (["--filter", "QuietHarnessTests|ChatScrollContinuityTests"], CONTINUITY),
            (["--filter", "QuietHarnessTests", "--filter", "[[:alpha:]]+ScrollContinuityTests"], CONTINUITY),
            (["--filter", "Chat", "--skip", "[[:alpha:]]+ScrollContinuityTests"], [BENCHMARK]),
            (["--filter", "ChatScrollContinuityTests", "--skip", "/testNativeMixedHeightScrollContinuity$"], CONTINUITY[:2] + CONTINUITY[3:]),
            (["--skip", "ChatScrollContinuityTests", "--skip=ChatTextMaterializationTests"], []),
            (["--skip", "ChatScrollContinuityTests|ChatTextMaterializationTests"], []),
            (["--specifier", CONTINUITY[2]], [CONTINUITY[2]]),
            (["-s", ALLOWED], []),
            (["--specifier", CONTINUITY[2], "--filter", "QuietHarnessTests"], []),
        ]
        for arguments, expected in cases:
            with self.subTest(arguments=arguments):
                self.assertEqual(RUNNER["live_console_tests"](NAMES, arguments), expected)

    def test_invalid_expressions_do_not_match(self) -> None:
        self.assertEqual(RUNNER["live_console_tests"](NAMES, ["--filter", "["]), [])
        self.assertEqual(
            RUNNER["live_console_tests"](NAMES, ["--filter", "ChatScrollContinuityTests", "--skip", "["]),
            CONTINUITY,
        )

    def test_environment_skip_override_takes_precedence_over_arguments(self) -> None:
        os.environ["_SWIFTPM_SKIP_TESTS_LIST"] = ""
        self.assertEqual(RUNNER["live_console_tests"](NAMES, ["--skip", "Chat"]), [*CONTINUITY, BENCHMARK])
        os.environ["_SWIFTPM_SKIP_TESTS_LIST"] = "ChatScrollContinuityTests:ChatTextMaterializationTests"
        self.assertEqual(RUNNER["live_console_tests"](NAMES, []), [])

    def test_environment_skip_file_uses_foundation_expressions(self) -> None:
        with tempfile.TemporaryDirectory(prefix="quiet-selection-") as scratch:
            skip_file = Path(scratch) / "skip-tests.txt"
            skip_file.write_text("[[:alpha:]]+ScrollContinuityTests\n\n")
            os.environ["_SWIFTPM_SKIP_TESTS_LIST"] = str(skip_file)
            self.assertEqual(RUNNER["live_console_tests"](NAMES, ["--skip", "Chat"]), [BENCHMARK])

    def test_locked_runner_refuses_before_launch_and_preserves_allowed_batches(self) -> None:
        cases = [
            (True, ["--filter", "[[:alpha:]]+ScrollContinuityTests"], 2, 0),
            (None, ["--filter", "[[:alpha:]]+ScrollContinuityTests"], 2, 0),
            (True, ["--filter", "QuietHarnessTests"], 0, 1),
            (True, ["--filter", "QuietHarnessTests|ChatScrollContinuityTests", "--skip", "[[:alpha:]]+ScrollContinuityTests"], 0, 1),
        ]
        for locked, arguments, expected_code, expected_launches in cases:
            with self.subTest(locked=locked, arguments=arguments):
                self.assertEqual(self.run_runner(locked, arguments), (expected_code, expected_launches))

    def test_selection_helper_failure_refuses_before_launch(self) -> None:
        self.assertEqual(self.run_runner(True, ["--filter", "QuietHarnessTests"], fail_selection=True), (2, 0))

    def test_passthrough_values_preserve_swiftpm_selection_boundaries(self) -> None:
        cases = [
            (["-Xswiftc", "-strict-concurrency=complete"], [*CONTINUITY, BENCHMARK]),
            (["-Xcc", "-std=gnu17"], [*CONTINUITY, BENCHMARK]),
            (["-Xcxx", "-std=c++17"], [*CONTINUITY, BENCHMARK]),
            (["-Xlinker", "-s"], [*CONTINUITY, BENCHMARK]),
            (["-Xswiftc=-strict-concurrency=complete"], [*CONTINUITY, BENCHMARK]),
            (["-Xswiftc", "--filter=QuietHarnessTests"], [*CONTINUITY, BENCHMARK]),
            (["-Xcc", "--skip=Chat"], [*CONTINUITY, BENCHMARK]),
            (["-Xlinker", "-s", "--filter", "QuietHarnessTests"], []),
            (["--filter", "Chat", "-Xswiftc", "-strict-concurrency=complete", "--skip", "ChatScrollContinuityTests"], [BENCHMARK]),
            (["-Xcc", "-std=gnu17", "--filter", "Chat|QuietHarnessTests", "--skip", "Chat"], []),
            (["--filter", "QuietHarnessTests", "-Xswiftc", "--filter", "--filter", "ChatScrollContinuityTests"], CONTINUITY),
        ]
        for arguments, expected in cases:
            with self.subTest(arguments=arguments):
                self.assertEqual(RUNNER["live_console_tests"](NAMES, arguments), expected)

    def test_locked_runner_refuses_passthrough_bypasses_and_unknown_arguments(self) -> None:
        cases = [
            ["-Xswiftc", "-strict-concurrency=complete"],
            ["-Xcc", "-std=gnu17"],
            ["-Xlinker", "-s"],
            ["-Xcxx", "-std=c++17"],
            ["-Xxcbuild", "-sdk=macosx"],
            ["-Xbuild-tools-swiftc", "-strict-concurrency=complete"],
            ["-Xmanifest", "-strict-concurrency=complete"],
            ["--unknown-option", "--filter", "QuietHarnessTests"],
            ["--unknown-option=anything", "--filter", "QuietHarnessTests"],
            ["-Xunknown", "-s", "--filter", "QuietHarnessTests"],
            ["last", "--filter", "QuietHarnessTests"],
            ["--", "--filter", "QuietHarnessTests"],
            ["--filter", "QuietHarnessTests", "--skip", "Chat", "--unknown-option"],
            ["--filter", "QuietHarnessTests", "-Xswiftc"],
            ["--filter", "QuietHarnessTests", "--jobs"],
            ["--filter", "QuietHarnessTests", "--skip"],
            ["--filter", "QuietHarnessTests", "--xunit-output", "--skip=Chat"],
            ["--filter", "QuietHarnessTests", "--parallel=true"],
            ["--filter", "QuietHarnessTests", "--filt=Chat"],
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                self.assertEqual(self.run_runner(True, arguments), (2, 0))

    def test_locked_runner_allows_filtered_batches_with_compiler_and_value_options(self) -> None:
        cases = [
            ["-Xswiftc", "-strict-concurrency=complete", "--filter", "QuietHarnessTests"],
            ["--filter", "QuietHarnessTests", "-Xcc", "-std=gnu17"],
            ["--filter", "QuietHarnessTests", "-Xcxx", "-std=c++17"],
            ["-Xlinker", "-s", "--filter", "Chat|QuietHarnessTests", "--skip", "Chat"],
            ["-Xxcbuild", "-sdk=macosx", "--filter", "QuietHarnessTests"],
            ["-Xbuild-tools-swiftc", "-strict-concurrency=complete", "--filter", "QuietHarnessTests"],
            ["-Xmanifest", "-strict-concurrency=complete", "--filter", "QuietHarnessTests"],
            ["--jobs", "4", "--filter=QuietHarnessTests", "--xunit-output", "results.xml"],
            ["-j4", "-cdebug", "-s" + ALLOWED],
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                self.assertEqual(self.run_runner(True, arguments), (0, 1))

    def test_runner_options_are_not_consumed_from_passthrough_values(self) -> None:
        cases = [
            ["-Xswiftc", "--skip-build", "--filter", "QuietHarnessTests"],
            ["-Xcc=--log-dir=compiler-value", "--filter", "QuietHarnessTests"],
            ["-Xlinker", "--log-dir", "--filter", "QuietHarnessTests"],
            ["-Xswiftc", "--help", "--filter", "QuietHarnessTests"],
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                self.assertEqual(self.run_runner(True, arguments), (0, 1))

    def run_runner(self, locked: bool | None, arguments: list[str], *, fail_selection: bool = False) -> tuple[int, int]:
        swift = subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip()
        real_run = subprocess.run
        root = Path(__file__).resolve().parent.parent
        (root / ".build").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="quiet-selection-", dir=root / ".build") as scratch:
            directory = Path(scratch)
            (directory / "libAgentPadQuietInterposer.dylib").touch()

            def discover_or_select(command: list[str], **kwargs) -> subprocess.CompletedProcess:
                if command[1] == "test":
                    self.assertEqual(kwargs["env"]["AGENTPAD_QUIET_TEST"], "1")
                    return subprocess.CompletedProcess(command, 0, "\n".join(NAMES), "QUIET PASS: discovery fixture\n")
                if fail_selection:
                    raise subprocess.CalledProcessError(1, command, stderr="selection helper failed\n")
                return real_run(command, **kwargs)

            def launch(command: list[str], **kwargs) -> int:
                self.assertEqual(kwargs["env"]["AGENTPAD_QUIET_TEST"], "1")
                self.assertEqual(kwargs["env"]["DYLD_INSERT_LIBRARIES"], str(directory / "libAgentPadQuietInterposer.dylib"))
                self.assertEqual(command[-len(arguments):], arguments)
                kwargs["stdout"].write("QUIET PASS: launch fixture\n")
                return 0

            argv = ["test-quiet.py", "--skip-build", "--log-dir", scratch, *arguments]
            with patch.dict(RUNNER["main"].__globals__, console_locked=lambda: locked), \
                 patch.object(sys, "argv", argv), \
                 patch.object(subprocess, "check_output", side_effect=[swift, str(directory)]), \
                 patch.object(subprocess, "run", side_effect=discover_or_select), \
                 patch.object(subprocess, "call", side_effect=launch) as invocation, \
                 contextlib.redirect_stdout(io.StringIO()):
                code = RUNNER["main"]()
            if fail_selection:
                self.assertEqual((directory / "selection.log").read_text(), "selection helper failed\n")
            return code, invocation.call_count


if __name__ == "__main__":
    unittest.main(verbosity=2)
