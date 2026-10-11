#!/usr/bin/env python3
"""Prepare an optional private build resource, outside the checkout.

No shell evaluation, credential argv, compiler flags, or credential output.
The release builder reads a 0600 env file in memory and provisions the generator
over a pipe. The private build input is 0600; the distributed app resource is
0644 so users other than the app's owner can read it.
"""
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys

NAMES = ("AGENTPAD_TELEGRAM_", "TELEGRAM_", "TG_", "")


def credentials(values):
    def one(suffix):
        found = {values[prefix + suffix] for prefix in NAMES if prefix + suffix in values}
        if len(found) > 1:
            raise ValueError()
        return next(iter(found), None)
    api_id, api_hash = one("API_ID"), one("API_HASH")
    if api_id is None and api_hash is None:
        return None
    if not api_id or not api_id.isascii() or not api_id.isdigit() or not 0 < int(api_id) < 2**31:
        raise ValueError()
    if not api_hash or not re.fullmatch(r"[a-fA-F0-9]{32}", api_hash):
        raise ValueError()
    return {"api_id": api_id, "api_hash": api_hash}


def read_source(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "r") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError()
        values = {}
        for line in source:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            match = re.fullmatch(r"(?:export\s+)?([A-Z_]+)\s*=\s*(.*?)\s*", line)
            if not match:
                raise ValueError()
            name, value = match.groups()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            values[name] = value
        return credentials(values)


def main():
    destination = Path(sys.argv[2]).resolve()
    checkout = Path(__file__).resolve().parent.parent
    if destination.is_relative_to(checkout):
        raise ValueError()
    if sys.argv[1] == "--bundle":
        # argv[2] is the private build input, still outside the checkout. The
        # bundled application pair is extractable, like other app resources.
        subprocess.run(["/usr/bin/install", "-m", "644", str(destination), sys.argv[3]],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return
    if sys.argv[1] == "--generate":
        value = json.load(sys.stdin)
        value = credentials({"API_ID": value["api_id"], "API_HASH": value["api_hash"]})
        fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as output:
            plistlib.dump(value, output, fmt=plistlib.FMT_BINARY)
        return
    if sys.argv[1] != "--prepare":
        raise ValueError()
    # Plain source builds are disabled unless explicitly configured. Releases
    # require a pair and default to the owner's protected external config file.
    required = os.environ.get("AGENTPAD_TELEGRAM_REQUIRE_CONFIG") == "1"
    source = os.environ.get("AGENTPAD_TELEGRAM_CONFIG_FILE")
    value = credentials(os.environ)
    if value is None and (source or required):
        value = read_source(source or os.path.expanduser("~/.config/agentpad/telegram.env"))
    if value is None:
        if required:
            raise ValueError()
        return
    clean_environment = {k: v for k, v in os.environ.items()
                         if k not in {p + s for p in NAMES for s in ("API_ID", "API_HASH")}}
    subprocess.run([sys.executable, "-I", __file__, "--generate", str(destination)],
                   input=json.dumps(value).encode(), env=clean_environment, check=True)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never render an exception, its arguments, the input, or a traceback.
        sys.stderr.write("Telegram build configuration is missing, invalid, or not a private 0600 file.\n")
        sys.exit(1)
