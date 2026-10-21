import argparse
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description="Run XCTest with mandatory invisible, silent containment and preserved geometry")
    parser.add_argument("--log-dir", type=Path, default=Path(".build/quiet-tests"))
    parser.add_argument("--skip-build", action="store_true")
    args, test_arguments = parser.parse_known_args()
    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    args.log_dir.mkdir(parents=True, exist_ok=True)
    swift = subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip()
    options = ["--disable-sandbox", "--cache-path", ".build/cache", "--config-path", ".build/config", "--security-path", ".build/security", "-j", "4"]
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
    console = plistlib.loads(subprocess.check_output(["ioreg", "-n", "Root", "-d1", "-a"]))
    if console.get("IOConsoleLocked") is not False:
        print("Quiet XCTest NOT RUN: IOConsoleLocked is not false")
        return 2
    binary_directory = Path(subprocess.check_output([swift, "build", "--show-bin-path"], text=True).strip())
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
        with (args.log_dir / "tests.log").open("w") as output:
            output.write("Preflight: IOConsoleLocked=false; QUIET; home/config/state under .build\n")
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
