#!/usr/bin/env python3
"""Render the small Markdown subset used by Sparkle release notes."""

import html
import re
import sys
from pathlib import Path


def inline(text):
    # Code is literal, including Markdown emphasis inside it. Escape all input;
    # release notes must not introduce scripts, images, or remote resources.
    parts = re.split(r"(`[^`]+`)", text)
    return "".join(
        "<code>" + html.escape(part[1:-1], quote=False) + "</code>"
        if part.startswith("`") and part.endswith("`") and len(part) > 2
        else re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", html.escape(part, quote=False))
        for part in parts
    )


def render(markdown):
    blocks, paragraph, items = [], [], []

    def flush():
        if paragraph:
            blocks.append("<p>" + inline(" ".join(paragraph)) + "</p>")
            paragraph.clear()
        if items:
            blocks.append("<ul>" + "".join("<li>" + inline(item) + "</li>" for item in items) + "</ul>")
            items.clear()

    skipping_install = False
    for line in markdown.splitlines():
        text = line.strip()
        if text.startswith("## "):
            flush()
            skipping_install = text[3:].strip() == "Install or update"
            if not skipping_install:
                blocks.append("<h3>" + inline(text[3:]) + "</h3>")
        elif skipping_install:
            continue
        elif not text:
            flush()
        elif text.startswith("- "):
            if paragraph:
                flush()
            items.append(text[2:])
        elif items:
            items[-1] += " " + text
        else:
            paragraph.append(text)
    flush()
    css = (
        "body{font:13px -apple-system,system-ui,sans-serif;line-height:1.45;margin:12px 16px;color:#1d1d1f;background:#fff}"
        "h3{font-size:13px;margin:14px 0 4px}p{margin:0 0 8px}ul{margin:0 0 8px;padding-left:18px}li{margin:2px 0}"
        "code{font:12px ui-monospace,Menlo,monospace;background:rgba(127,127,127,.15);padding:0 3px;border-radius:3px}"
        "@media (prefers-color-scheme:dark){body{color:#e8e8ea;background:#1e1f22}}"
    )
    return '<!DOCTYPE html><html><head><meta charset="utf-8"><style>' + css + "</style></head><body>" + "".join(blocks) + "</body></html>"


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: notes2html.py NOTES.md")
    print(render(Path(sys.argv[1]).read_text(encoding="utf-8")))
