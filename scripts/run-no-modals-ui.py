import argparse
import concurrent.futures
import json
import os
import plistlib
import subprocess
import tempfile
import time
from pathlib import Path


BATCHES = ["main", "settings", "local", "connection", "composition", "publication",
           "organization", "operations", "folders", "telegram", "video", "fallback", "startup"]


def screen_unlocked() -> bool:
    root = plistlib.loads(subprocess.check_output(["ioreg", "-n", "Root", "-d1", "-a"]))
    return root.get("IOConsoleLocked") is False


def run_batch(binary: Path, batch: str, shots: Path) -> dict:
    shots.mkdir(parents=True, exist_ok=True)
    log = shots / "native.log"
    started = time.monotonic()
    libraries = [binary.parent / name for name in
                 ("libAgentPadQuietInterposer.dylib", "libAgentPadQuietTestSupport.dylib")]
    for library in libraries:
        if not library.is_file():
            raise RuntimeError(f"Quiet test library is missing: {library.name}; run swift build first")
    if not screen_unlocked():
        log.write_text("NOT RUN: IOConsoleLocked is not false\n")
        return {"batch": batch, "exit": 2, "seconds": 0, "log": str(log)}
    with tempfile.TemporaryDirectory(prefix=f"quiet-{batch}-", dir=Path.cwd() / ".build") as scratch:
        root = Path(scratch)
        (root / "tmp").mkdir()
        child_environment = dict(os.environ, HOME=scratch, CFFIXED_USER_HOME=scratch,
                                 TMPDIR=str(root / "tmp"), AGENTPAD_QUIET_TEST="1",
                                 DYLD_INSERT_LIBRARIES=":".join(map(str, libraries)),
                                 AGENTPAD_DEBUG_STATE_PATH=str(root / "state-v2.json"),
                                 AGENTPAD_DEBUG_CONFIG_DIRECTORY=str(root / "config"),
                                 AGENTPAD_POPUP_SHOTS=str(shots))
        child_environment.pop("AGENTPAD_POPUP_PHASE3_BATCH", None)
        if batch not in {"main", "startup"}:
            child_environment["AGENTPAD_POPUP_PHASE3_BATCH"] = batch
        arguments = [str(binary), "--self-check-first-launch", "capture"] if batch == "startup" else [str(binary), "--self-check-no-modals"]
        with log.open("w") as output:
            output.write("Preflight: IOConsoleLocked=false; QUIET mode; isolated home/config/state under .build\n")
            output.flush()
            process = subprocess.Popen(arguments, env=child_environment, stdout=output, stderr=subprocess.STDOUT)
            try:
                code = process.wait(timeout=360)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                output.write("FAIL: native process exceeded 360 seconds; stopped by PID\n")
                code = 124
        content = log.read_text()
        if "QUIET FAIL:" in content or (code == 0 and "QUIET PASS:" not in content):
            code = 1
            with log.open("a") as output:
                output.write("FAIL: quietness proof failed or missing\n")
        result = {"batch": batch, "exit": code, "seconds": round(time.monotonic() - started, 2), "log": str(log)}
        print(f"Quiet matrix {batch}: {'PASS' if code == 0 else 'FAIL'} (exit {code}, {result['seconds']}s); {log}", flush=True)
        if code:
            print("\n".join(content.splitlines()[-12:]), flush=True)
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--concurrency", type=int, default=3)
    parser.add_argument("--batch", choices=BATCHES, default=os.environ.get("AGENTPAD_POPUP_PHASE3_BATCH"))
    args = parser.parse_args()
    if args.concurrency < 1:
        parser.error("--concurrency must be positive")
    root = Path(os.environ.get("AGENTPAD_POPUP_SHOTS", str(Path.cwd() / ".build/pop1-shots"))).resolve()
    batches = [args.batch] if args.batch else ["main"] if os.environ.get("AGENTPAD_POPUP_CAPTURE_ONLY") == "1" else BATCHES
    root.mkdir(parents=True, exist_ok=True)
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = [pool.submit(run_batch, args.binary.resolve(), batch, root if len(batches) == 1 else root / batch) for batch in batches]
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())
            (root / "run-results.json").write_text(json.dumps(sorted(results, key=lambda row: row["batch"]), indent=2) + "\n")
    return int(any(row["exit"] != 0 for row in results))


if __name__ == "__main__":
    raise SystemExit(main())
