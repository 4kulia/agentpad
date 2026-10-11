#!/usr/bin/env python3
"""Reject build-host dynamic dependencies and accidental static framework copies."""
from pathlib import Path
import subprocess
import sys

app = Path(sys.argv[1])
for path in app.rglob("*"):
    if path.name in ("TDLibFramework.framework", "TDLibFramework.xcframework"):
        sys.exit("Static TDLib artifacts must not be embedded in the app.")
    if path.is_symlink() or not path.is_file():
        continue
    kind = subprocess.check_output(["file", "-b", str(path)], text=True)
    if "Mach-O" not in kind:
        continue
    dependencies = subprocess.check_output(["otool", "-L", str(path)], text=True)
    for line in dependencies.splitlines():
        # Universal Sparkle binaries repeat a non-indented file/architecture
        # header before each slice. Only indented entries are load commands.
        if not line[:1].isspace():
            continue
        dependency = line.strip().split(" (", 1)[0]
        if not dependency.startswith(("/usr/lib/", "/System/Library/", "@rpath/", "@loader_path/", "@executable_path/")):
            sys.exit(f"Non-system absolute dynamic dependency in {path.relative_to(app)}.")
print("Verified packaged Mach-O dependencies; TDLib is statically linked.")
