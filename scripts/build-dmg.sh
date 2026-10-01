#!/usr/bin/env bash
# Build a distributable DMG from dist/AgentPad.app — standard
# drag-to-Applications layout with /Applications symlink.
#
# Run scripts/build-app.sh first (or invoke this with --build to chain).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ "${1:-}" = "--build" ]; then
    ./scripts/build-app.sh
fi

APP="dist/AgentPad.app"
[ -d "$APP" ] || {
    echo "build-dmg.sh: ${APP} not found. Run scripts/build-app.sh first (or pass --build)." >&2
    exit 1
}

VERSION="$(plutil -extract CFBundleShortVersionString raw "${APP}/Contents/Info.plist")"
DMG="dist/AgentPad-v${VERSION}.dmg"
STAGING="dist/dmg-staging"

echo "==> Staging ${APP} for DMG (v${VERSION})"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating ${DMG}"
# UDZO = zlib-compressed read-only — standard format for distribution.
hdiutil create \
    -volname "AgentPad" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

# Adhoc-sign the DMG itself so macOS doesn't flag the *file* as unsigned
# even before the user mounts it. Inner .app already has its own adhoc sig.
codesign --force --sign - "$DMG"

rm -rf "$STAGING"

SIZE="$(du -h "$DMG" | awk '{print $1}')"
echo ""
echo "✓ Built ${DMG} (${SIZE})"
echo "  open ${DMG}                # mount + see drag-to-install layout"
echo "  shasum -a 256 ${DMG}       # checksum for release notes"
