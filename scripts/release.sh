#!/usr/bin/env bash
# Build the installer other people can open: a DMG whose app is signed with a
# Developer ID certificate and notarized by Apple, so Gatekeeper lets it run
# on a Mac that never saw the source.
#
# One-time setup (needs a paid Apple Developer Program membership):
#   1. A "Developer ID Application" certificate in the login keychain:
#      Xcode → Settings → Accounts → Manage Certificates → + .
#   2. Notary credentials stored under a profile name:
#      xcrun notarytool store-credentials agentpad-notary \
#          --apple-id <apple-id> --team-id <TEAMID>
#      (asks for an app-specific password from account.apple.com)
#
# Usage:
#   scripts/release.sh
#
# Environment:
#   AGENTPAD_SIGN_IDENTITY   certificate to sign with; defaults to the only
#                            "Developer ID Application" identity in the keychain
#   AGENTPAD_NOTARY_PROFILE  notarytool keychain profile (default: agentpad-notary)
#
# Note: this rebuilds dist/AgentPad.app in place. Quit an AgentPad that is
# running from dist/ first, or run your everyday copy from /Applications.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROFILE="${AGENTPAD_NOTARY_PROFILE:-agentpad-notary}"
APP="dist/AgentPad.app"

echo "==> Checking signing identity"
if [ -z "${AGENTPAD_SIGN_IDENTITY:-}" ]; then
    IDENTITIES="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p')"
    COUNT="$(printf '%s' "$IDENTITIES" | grep -c . || true)"
    if [ "$COUNT" = 0 ]; then
        echo "release.sh: no \"Developer ID Application\" certificate in the keychain." >&2
        echo "  Create one in Xcode → Settings → Accounts → Manage Certificates, then re-run." >&2
        exit 1
    elif [ "$COUNT" != 1 ]; then
        echo "release.sh: several Developer ID certificates found; pick one with AGENTPAD_SIGN_IDENTITY:" >&2
        printf '%s\n' "$IDENTITIES" | sed 's/^/  /' >&2
        exit 1
    fi
    AGENTPAD_SIGN_IDENTITY="$IDENTITIES"
fi
export AGENTPAD_SIGN_IDENTITY
echo "    ${AGENTPAD_SIGN_IDENTITY}"

echo "==> Checking notary profile \"${PROFILE}\""
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "release.sh: notarytool cannot use the keychain profile \"${PROFILE}\"." >&2
    echo "  Store credentials with: xcrun notarytool store-credentials ${PROFILE} --apple-id <apple-id> --team-id <TEAMID>" >&2
    exit 1
fi

notarize() {
    # Prints Apple's log when a submission is rejected: the reason is only there.
    local file="$1" output id
    output="$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait 2>&1)" || true
    printf '%s\n' "$output" | tail -4
    if ! printf '%s\n' "$output" | grep -q "status: Accepted"; then
        id="$(printf '%s\n' "$output" | sed -n 's/^ *id: //p' | head -1)"
        [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
        echo "release.sh: notarization of ${file} was not accepted." >&2
        exit 1
    fi
}

./scripts/build-app.sh

echo "==> Verifying the app signature"
codesign --verify --deep --strict "$APP"

echo "==> Notarizing the app"
ZIP="dist/AgentPad-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
rm -f "$ZIP"
# Stapled before the image is built, so the app passes Gatekeeper offline
# once it has been dragged out of the DMG.
xcrun stapler staple "$APP"

./scripts/build-dmg.sh
DMG="$(ls -t dist/AgentPad-v*.dmg | head -1)"

echo "==> Notarizing ${DMG}"
notarize "$DMG"
xcrun stapler staple "$DMG"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo ""
echo "✓ Release image: ${DMG}"
echo "  shasum -a 256 ${DMG}"
