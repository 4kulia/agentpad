#!/usr/bin/env python3
"""Rename the upstream project's name to AgentPad across the tree.

AgentPad is a fork; upstream keeps shipping under its own name. Renaming by
hand would make every upstream merge conflict, so the rename is this script
instead: deterministic and idempotent, it can be re-applied to a fresh
upstream tree before that tree is merged (see docs/agentpad/ROADMAP.md).

    scripts/rebrand.py            # rewrite file contents and rename paths
    scripts/rebrand.py --check    # exit 1 if an unprotected mention remains
    scripts/rebrand.py --dry-run  # list what would change, touch nothing

What is deliberately left alone:
  * LICENSE, NOTICE.md, CHANGELOG.md, README*.md — attribution and upstream
    history (the MIT licence requires the copyright notice to stay);
  * the phrases in PROTECTED — links to the upstream repository and credits.
"""

import argparse
import os
import re
import subprocess
import sys

OLD = "kooky"

# Files whose contents and names are never touched.
EXCLUDED = re.compile(r"^(LICENSE|NOTICE\.md|CHANGELOG\.md|README[^/]*\.md|scripts/rebrand\.py|Sources/AgentPadKit/AgentPad/LegacyNames\.swift)$")

# Substrings kept verbatim wherever they occur.
PROTECTED = [
    "iAmCorey/kooky",      # upstream repository: release downloads, discussions
    "utm_source=kooky",    # the upstream author's link in About
    "fork of kooky",       # credit line
    "upstream Kooky",      # comments that mean the original app
    "upstream kooky",
]

# Renames that are not mechanical.
SPECIAL = [
    # Upstream's bundle id maps to ours.
    ("com.iamcorey.kooky", "com.4kulia.agentpad"),
    # A fuzzy-matcher fixture whose first "p" must come after the hyphen;
    # "agentpad-project" would put one mid-word and invert the test.
    ("kooky-project", "demo-project"),
]

# A bare lowercase word in prose or a UI string is the product name; anything
# glued to identifier or path punctuation is a technical name.
QUOTED_BARE = re.compile(r'(?<=")kooky(?=\\?")')
BARE_WORD = re.compile(r"(?<![A-Za-z0-9_\-./:$~=@])kooky(?![A-Za-z0-9_\-/:=@]|\.[A-Za-z0-9_])")
CAMEL_PREFIX = re.compile(r"kooky(?=[A-Z])")
ANY = re.compile(OLD, re.IGNORECASE)


def rename_identifier(text: str) -> str:
    text = text.replace("KOOKY", "AGENTPAD").replace("Kooky", "AgentPad")
    text = CAMEL_PREFIX.sub("agentPad", text)
    return text.replace("kooky", "agentpad")


def rename_text(text: str) -> str:
    for old, new in SPECIAL:
        text = text.replace(old, new)
    for index, phrase in enumerate(PROTECTED):
        text = text.replace(phrase, f"\x00{index}\x00")
    text = QUOTED_BARE.sub("agentpad", text)
    text = BARE_WORD.sub("AgentPad", text)
    text = rename_identifier(text)
    for index, phrase in enumerate(PROTECTED):
        text = text.replace(f"\x00{index}\x00", phrase)
    return text


def drop_duplicate_entries(text: str) -> str:
    """Upstream localises both "Quit Kooky" and "Quit kooky"; after the rename
    the two entries are the same line, and a .strings file must not repeat a key."""
    seen, kept = set(), []
    for line in text.split("\n"):
        if line.startswith('"') and line in seen:
            continue
        seen.add(line)
        kept.append(line)
    return "\n".join(kept)


def unprotected_mentions(text: str) -> int:
    for phrase in PROTECTED:
        text = text.replace(phrase, "")
    return len(ANY.findall(text))


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def listed_files():
    tracked = set(filter(None, git("ls-files", "-z").split("\0")))
    untracked = set(filter(None, git("ls-files", "-z", "--others", "--exclude-standard").split("\0")))
    for path in sorted(tracked | untracked):
        if not EXCLUDED.match(path) and os.path.isfile(path) and not os.path.islink(path):
            yield path, path in tracked


def read_text(path: str):
    with open(path, "rb") as handle:
        data = handle.read()
    if b"\0" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="report remaining mentions, change nothing")
    mode.add_argument("--dry-run", action="store_true", help="list what would change, change nothing")
    args = parser.parse_args()

    os.chdir(git("rev-parse", "--show-toplevel").strip())
    files = list(listed_files())

    if args.check:
        failures = 0
        for path, _ in files:
            if ANY.search(path):
                print(f"path: {path}")
                failures += 1
            text = read_text(path)
            if text is not None and (count := unprotected_mentions(text)):
                print(f"{count:5d}  {path}")
                failures += 1
        print("clean" if not failures else f"{failures} file(s) still mention the upstream name")
        return 1 if failures else 0

    rewritten = moved = 0
    for path, tracked in files:
        text = read_text(path)
        if text is not None:
            updated = rename_text(text)
            if path.endswith(".strings"):
                updated = drop_duplicate_entries(updated)
            if updated != text:
                rewritten += 1
                if args.dry_run:
                    print(f"rewrite {path}")
                else:
                    with open(path, "w", encoding="utf-8", newline="") as handle:
                        handle.write(updated)

        target = rename_identifier(path)
        if target != path:
            moved += 1
            if args.dry_run:
                print(f"move    {path} -> {target}")
                continue
            os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
            if tracked:
                git("mv", path, target)
            else:
                os.rename(path, target)
            parent = os.path.dirname(path)
            while parent and not os.listdir(parent):
                os.rmdir(parent)
                parent = os.path.dirname(parent)

    verb = "would be" if args.dry_run else "were"
    print(f"{rewritten} file(s) {verb} rewritten, {moved} path(s) {verb} moved")
    return 0


if __name__ == "__main__":
    sys.exit(main())
