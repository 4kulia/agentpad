#!/usr/bin/env python3
"""Reject build-host dynamic dependencies and accidental static framework copies."""
import argparse
from pathlib import Path
import subprocess
import sys


def verify_quiet_isolation(binary: Path) -> None:
    for command in (["nm", "-a"], ["otool", "-L"], ["otool", "-l"]):
        output = subprocess.check_output([*command, str(binary)], text=True)
        if any(marker in output for marker in ("APQuiet", "AgentPadQuietTestSupport", "AgentPadQuietInterposer", "apq_")):
            sys.exit(f"Quiet test support must not be linked into the release product: {binary.name} ({command[0]}).")


def verify_dependencies(path: Path, app: Path) -> None:
    dependencies = subprocess.check_output(["otool", "-L", str(path)], text=True)
    for line in dependencies.splitlines():
        # Universal Sparkle binaries repeat a non-indented file/architecture
        # header before each slice. Only indented entries are load commands.
        if not line[:1].isspace():
            continue
        dependency = line.strip().split(" (", 1)[0]
        if not dependency.startswith(("/usr/lib/", "/System/Library/", "@rpath/", "@loader_path/", "@executable_path/")):
            sys.exit(f"Non-system absolute dynamic dependency in {path.relative_to(app)}.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("--binary", action="store_true")
    args = parser.parse_args()
    if args.binary:
        verify_quiet_isolation(args.path)
        print("Verified release binary has no quiet test support.")
        return
    app = args.path
    verify_quiet_isolation(app / "Contents/MacOS/AgentPad")
    for path in app.rglob("*"):
        if path.name in ("TDLibFramework.framework", "TDLibFramework.xcframework"):
            sys.exit("Static TDLib artifacts must not be embedded in the app.")
        if path.is_symlink() or not path.is_file():
            continue
        kind = subprocess.check_output(["file", "-b", str(path)], text=True)
        if "Mach-O" in kind:
            verify_dependencies(path, app)
    print("Verified packaged Mach-O dependencies; TDLib is statically linked; quiet test support is absent.")


if __name__ == "__main__":
    main()
