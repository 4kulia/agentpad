import argparse
import json
import os
import plistlib
import subprocess
import sys
import tempfile
from collections.abc import Iterator
from pathlib import Path


LIVE_CONSOLE_SUITES = {
    "ChatScrollContinuityTests", "ChatScrollRestorationTests", "ChatScrollMediaTests",
    "ChatScrollInputTests", "ChatScrollHarnessTests", "ChatTimelineReferenceTests", "ChatNativeTextCaptureTests",
    "ChatNativeScrollTests", "ChatScrollBenchmarkTests",
    "ChatNativeLifecycleTests", "ChatNativeAccessibilityTests", "ChatNativeNavigationTests",
    "ChatNativeRowActionTests", "ChatNativeServiceActionTests", "ChatNativeDMActionTests", "ChatNativeActionCaptureTests",
    "ChatNativeMetadataTests", "ChatNativeMetadataCaptureTests", "ChatNativeAgentActionTests", "ChatNativeReactorsTests",
    "ChatNativeParityReviewTests", "ChatNativeParityRowCaptureTests", "ChatNativeIntegrationParityTests",
    "ChatNativeSnapshotParityReviewTests", "ChatNativeMediaCaptureTests",
    "ChatNativeCompositionParityTests", "ChatNativeReactorWindowCaptureTests",
    "ChatPopupCaptureTests", "PopupDraftVisibilityTests",
}
LIVE_CONSOLE_BENCHMARKS = {
    "ChatRowMaterializationTests/testProfileProductionRowsAttachmentsReactionsAndAvatars",
    "ChatTextMaterializationTests/testProfileNativeTextMaterializationByRowType",
}
# The 2026-10-23/24 lock experiment delivered 960 scroll events with zero movement;
# chat reference capture also failed before rendering. These suites and render
# benchmarks need a live scroll/render pipeline. QuietHarness, EmptyPaneClose,
# TerminalMouse and WindowFramePersistence passed unchanged while locked, and
# native folder popup captures were pixel-identical. Do not gate all AppKit tests.


SWIFTPM_PASSTHROUGH_OPTIONS = {
    "-Xcc", "-Xswiftc", "-Xlinker", "-Xcxx", "-Xxcbuild", "-Xbuild-tools-swiftc", "-Xmanifest",
}
SWIFTPM_VALUE_OPTIONS = {
    "--package-path", "--cache-path", "--config-path", "--security-path", "--scratch-path",
    "--build-path", "--multiroot-data-file", "--destination", "--experimental-swift-sdks-path",
    "--swift-sdks-path", "--toolset", "--pkg-config-path", "--package-manager-resources-directory",
    "--manifest-cache", "--experimental-prebuilts-download-url", "--experimental-prebuilts-root-cert",
    "--netrc-file", "--resolver-fingerprint-checking", "--resolver-signing-entity-checking",
    "--default-registry-url", "-c", "--configuration", "--triple", "--sdk", "--toolchain", "--arch",
    "--experimental-swift-sdk", "--swift-sdk", "--sanitize", "-j", "--jobs",
    "--explicit-target-dependency-import-check", "--build-system", "-debug-info-format",
    "--experimental-test-entry-point-path", "--experimental-lto-mode", "--experimental-trace-events-file",
    "--experimental-codesize-profile-output-dir", "--traits", "--test-product", "--configuration-path",
    "--event-stream-output-path", "--event-stream-version", "--attachments-path",
    "--experimental-configuration-path", "--experimental-event-stream-output",
    "--experimental-event-stream-version", "--experimental-attachments-path",
    "--num-workers", "--experimental-maximum-parallelization-width", "--maximum-repetitions",
    "--repeat-until", "-s", "--specifier", "--filter", "--skip", "--xunit-output", "--test-output",
}
SWIFTPM_FLAGS = {
    "--ignore-lock", "--experimental-skip-acquiring-lock", "--enable-dependency-cache",
    "--disable-dependency-cache", "--disable-package-manifest-caching", "--enable-build-manifest-caching",
    "--disable-build-manifest-caching", "--enable-experimental-prebuilts", "--disable-experimental-prebuilts",
    "-v", "--verbose", "--very-verbose", "--vv", "-q", "--quiet", "--color-diagnostics",
    "--no-color-diagnostics", "--disable-sandbox", "--netrc", "--enable-netrc", "--disable-netrc",
    "--enable-keychain", "--disable-keychain", "--enable-signature-validation", "--disable-signature-validation",
    "--enable-prefetching", "--disable-prefetching", "--force-resolved-versions",
    "--disable-automatic-resolution", "--only-use-versions-from-resolved-file", "--skip-update",
    "--disable-scm-to-registry-transformation", "--use-registry-identity-for-scm", "--replace-scm-with-registry",
    "--experimental-prune-unused-dependencies", "--auto-index-store", "--enable-index-store",
    "--disable-index-store", "--experimental-prepare-for-indexing", "--experimental-prepare-for-indexing-no-lazy",
    "--experimental-xcframeworks-on-linux", "--enable-parseable-module-interfaces", "--use-integrated-swift-driver",
    "--enable-test-discovery", "--enable-get-task-allow-entitlement", "--disable-get-task-allow-entitlement",
    "--omit-frame-pointers", "--no-omit-frame-pointers", "--experimental-task-backtraces",
    "--experimental-build-dylibs-as-frameworks", "--experimental-enable-codesize-profile",
    "--enable-experimental-strip-products", "--disable-experimental-strip-products",
    "--enable-dead-strip", "--disable-dead-strip", "--disable-local-rpath", "--enable-all-traits",
    "--disable-default-traits", "--skip-build", "--enable-xctest", "--disable-xctest",
    "--enable-swift-testing", "--disable-swift-testing", "--parallel", "--no-parallel", "-l", "--list-tests",
    "--show-codecov-path", "--show-code-coverage-path", "--show-coverage-path", "--experimental-xunit-message-failure",
    "--enable-testable-imports", "--disable-testable-imports", "--enable-code-coverage", "--disable-code-coverage",
    "--version", "-h", "-help", "--help",
}


def argument_groups(arguments: list[str], *, runner_options: bool = False) -> Iterator[tuple[str, str | None, list[str]]]:
    value_options = SWIFTPM_VALUE_OPTIONS | SWIFTPM_PASSTHROUGH_OPTIONS
    if runner_options:
        value_options = value_options | {"--log-dir"}
    remaining = iter(arguments)
    for argument in remaining:
        option, equals, value = argument.partition("=")
        original = [argument]
        if option not in value_options and option not in SWIFTPM_FLAGS and argument[:2] in {"-s", "-c", "-j"}:
            option, equals, value = argument[:2], "=", argument[2:]
        if option in value_options:
            if not equals:
                value = next(remaining, None)
                if value is None or (option not in SWIFTPM_PASSTHROUGH_OPTIONS and value.startswith("-")):
                    raise ValueError(f"Missing value for {option}")
                original.append(value)
            yield option, value, original
        elif option in SWIFTPM_FLAGS and not equals:
            yield option, None, original
        else:
            raise ValueError(f"Unsupported SwiftPM argument: {argument}")


def console_locked() -> bool | None:
    console = plistlib.loads(subprocess.check_output(["ioreg", "-n", "Root", "-d1", "-a"]))
    return console.get("IOConsoleLocked")


def live_console_tests(names: list[str], arguments: list[str], *, swift: str | None = None,
                       environment: dict[str, str] | None = None) -> list[str]:
    filters = []
    skips = []
    specifier = None
    for option, value, _ in argument_groups(arguments):
        if option == "--filter":
            filters.append(value)
        elif option == "--skip":
            skips.append(value)
        elif option in {"-s", "--specifier"}:
            specifier = value
    helper = Path(__file__).with_name("swift-test-selection.swift")
    command = [swift] if swift else ["xcrun", "swift"]
    selection_result = subprocess.run(
        [*command, "-module-cache-path", str(helper.parent.parent / ".build/ModuleCache"), str(helper)],
        input=json.dumps({"names": names, "filters": filters, "skips": skips, "specifier": specifier}),
        env=environment, capture_output=True, text=True, check=True,
    )
    selected = []
    for name in json.loads(selection_result.stdout):
        suite, separator, method = name.rpartition(".")[2].partition("/")
        if separator and (suite in LIVE_CONSOLE_SUITES or f"{suite}/{method}" in LIVE_CONSOLE_BENCHMARKS):
            selected.append(name)
    return selected


def main() -> int:
    parser = argparse.ArgumentParser(description="Run XCTest with mandatory invisible, silent containment and preserved geometry", add_help=False, allow_abbrev=False)
    parser.add_argument("-h", "-help", "--help", action="help")
    parser.add_argument("--log-dir", type=Path, default=Path(".build/quiet-tests"))
    parser.add_argument("--skip-build", action="store_true")
    runner_arguments = []
    test_arguments = []
    try:
        for option, _, original in argument_groups(sys.argv[1:], runner_options=True):
            if option in {"--log-dir", "--skip-build", "-h", "-help", "--help"}:
                runner_arguments.extend(original)
            else:
                test_arguments.extend(original)
    except ValueError as error:
        print(f"Quiet XCTest NOT RUN: {error}", flush=True)
        return 2
    args = parser.parse_args(runner_arguments)
    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    args.log_dir.mkdir(parents=True, exist_ok=True)
    locked = console_locked()
    preflight = f"Preflight: IOConsoleLocked={json.dumps(locked)}; QUIET; home/config/state under .build\n"
    (args.log_dir / "tests.log").write_text(preflight)
    print(preflight.strip(), flush=True)
    swift = subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip()
    options = ["--disable-sandbox", "--disable-keychain", "--disable-netrc", "--cache-path", ".build/cache", "--config-path", ".build/config", "--security-path", ".build/security", "-j", "4"]
    # Compile W09 observation only for its opt-in capture run. Rebuild when
    # entering/leaving this mode; --skip-build requires a matching prior build.
    if os.environ.get("AGENTPAD_CHAT_NATIVE_W09_CAPTURE") == "1":
        options.extend(["-Xswiftc", "-DAGENTPAD_CHAT_NATIVE_W09_CAPTURE"])
    build_home = root / ".build/quiet-build-home"
    (build_home / "tmp").mkdir(parents=True, exist_ok=True)
    build_environment = dict(os.environ, HOME=str(build_home), CFFIXED_USER_HOME=str(build_home),
                             TMPDIR=str(build_home / "tmp"), CLANG_MODULE_CACHE_PATH=str(root / ".build/ModuleCache"))
    if not args.skip_build:
        with (args.log_dir / "build.log").open("w") as output:
            code = subprocess.call([swift, "build", "--build-tests", *options], env=build_environment, stdout=output, stderr=subprocess.STDOUT)
        print(f"Quiet XCTest build: exit={code}; {args.log_dir / 'build.log'}", flush=True)
        if code:
            print("\n".join((args.log_dir / "build.log").read_text().splitlines()[-30:]))
            return code
    binary_directory = Path(subprocess.check_output([swift, "build", "--disable-keychain", "--disable-netrc", "--show-bin-path"], text=True).strip())
    interposer = binary_directory / "libAgentPadQuietInterposer.dylib"
    if not interposer.is_file():
        raise RuntimeError("Quiet audio/input interposer is missing; run swift build first")
    with tempfile.TemporaryDirectory(prefix="quiet-xctest-", dir=root / ".build") as scratch:
        home = Path(scratch)
        (home / "tmp").mkdir()
        child_environment = dict(os.environ, HOME=scratch, CFFIXED_USER_HOME=scratch,
                                 TMPDIR=str(home / "tmp"), AGENTPAD_QUIET_TEST="1",
                                 DYLD_INSERT_LIBRARIES=str(interposer),
                                 AGENTPAD_DEBUG_STATE_PATH=str(home / "state-v2.json"),
                                 AGENTPAD_DEBUG_CONFIG_DIRECTORY=str(home / "config"))
        with (args.log_dir / "tests.log").open("a") as output:
            locked = console_locked()
            output.write(f"Launch: IOConsoleLocked={json.dumps(locked)}; QUIET\n")
            if locked is not False:
                discovery = subprocess.run([swift, "test", *options, "list", "--skip-build"],
                                           env=child_environment, capture_output=True, text=True)
                (args.log_dir / "discovery.log").write_text(discovery.stdout + discovery.stderr)
                if discovery.returncode or "QUIET FAIL:" in discovery.stdout + discovery.stderr:
                    message = "Quiet XCTest NOT RUN: quiet test discovery failed; see discovery.log"
                    output.write(message + "\n")
                    print(message, flush=True)
                    return discovery.returncode or 1
                try:
                    blocked = live_console_tests(discovery.stdout.splitlines(), test_arguments,
                                                 swift=swift, environment=build_environment)
                except (subprocess.CalledProcessError, OSError, ValueError) as error:
                    detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
                    (args.log_dir / "selection.log").write_text(detail)
                    message = "Quiet XCTest NOT RUN: SwiftPM test selection failed; see selection.log"
                    output.write(message + "\n")
                    print(message, flush=True)
                    return 2
                if blocked:
                    message = "Quiet XCTest NOT RUN: live scroll/render pipeline requires IOConsoleLocked=false: " + ", ".join(blocked)
                    output.write(message + "\n")
                    print(message, flush=True)
                    return 2
            output.flush()
            code = subprocess.call([swift, "test", "--skip-build", *options, *test_arguments], env=child_environment, stdout=output, stderr=subprocess.STDOUT)
    content = (args.log_dir / "tests.log").read_text()
    if "QUIET FAIL:" in content or (code == 0 and "QUIET PASS:" not in content):
        print("Quiet XCTest FAIL: quietness proof failed or missing")
        code = 1
    print("\n".join(content.splitlines()[-30:]))
    print(f"Quiet XCTest: exit={code}; {args.log_dir / 'tests.log'}")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
