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
#      Or, without the keychain: an App Store Connect API key
#      (App Store Connect → Users and Access → Integrations → Team Keys),
#      saved as ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8, and
#      AGENTPAD_NOTARY_KEY_ID / AGENTPAD_NOTARY_ISSUER set (see below).
#
# Usage:
#   scripts/release.sh
#
# Environment:
#   AGENTPAD_SIGN_IDENTITY   certificate to sign with; defaults to the only
#                            "Developer ID Application" identity in the keychain
#   AGENTPAD_NOTARY_PROFILE  notarytool keychain profile (default: agentpad-notary)
#   AGENTPAD_NOTARY_KEY_ID   App Store Connect API key id; with
#   AGENTPAD_NOTARY_ISSUER   its issuer id, used instead of the profile
#   AGENTPAD_RELEASE_NOTES  optional Markdown file embedded in the Sparkle
#                            update window; otherwise link to the GitHub release
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

if [ -n "${AGENTPAD_NOTARY_KEY_ID:-}" ]; then
    KEY_FILE="${HOME}/.appstoreconnect/private_keys/AuthKey_${AGENTPAD_NOTARY_KEY_ID}.p8"
    [ -n "${AGENTPAD_NOTARY_ISSUER:-}" ] || { echo "release.sh: AGENTPAD_NOTARY_ISSUER is not set." >&2; exit 1; }
    [ -r "$KEY_FILE" ] || { echo "release.sh: cannot read ${KEY_FILE}." >&2; exit 1; }
    NOTARY_AUTH=(--key "$KEY_FILE" --key-id "$AGENTPAD_NOTARY_KEY_ID" --issuer "$AGENTPAD_NOTARY_ISSUER")
    echo "==> Checking notary API key ${AGENTPAD_NOTARY_KEY_ID}"
else
    NOTARY_AUTH=(--keychain-profile "$PROFILE")
    echo "==> Checking notary profile \"${PROFILE}\""
fi
if ! xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1; then
    echo "release.sh: notarytool cannot sign in with ${NOTARY_AUTH[*]}." >&2
    echo "  Store credentials with: xcrun notarytool store-credentials ${PROFILE} --apple-id <apple-id> --team-id <TEAMID>" >&2
    exit 1
fi

notarize() {
    # Prints Apple's log when a submission is rejected: the reason is only there.
    local file="$1" output id
    output="$(xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" --wait 2>&1)" || true
    printf '%s\n' "$output" | tail -4
    if ! printf '%s\n' "$output" | grep -q "status: Accepted"; then
        id="$(printf '%s\n' "$output" | sed -n 's/^ *id: //p' | head -1)"
        [ -z "$id" ] || xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2 || true
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

echo "==> Sparkle appcast"
# The feed AgentPad reads (SUFeedURL): the appcast attached to the latest
# GitHub release, pointing at this release's DMG and signed with the EdDSA
# key in the keychain (account "agentpad", made by Sparkle's generate_keys).
SIGN_UPDATE="$(find .build/artifacts -path '*Sparkle/bin/sign_update' -not -path '*old_dsa*' | head -1)"
[ -x "$SIGN_UPDATE" ] || { echo "release.sh: Sparkle's sign_update not found under .build/artifacts" >&2; exit 1; }
VERSION="$(plutil -extract CFBundleShortVersionString raw "${APP}/Contents/Info.plist")"
ED_ATTRS="$("$SIGN_UPDATE" --account agentpad "$DMG")"
case "$ED_ATTRS" in *edSignature=*length=*) ;; *) echo "release.sh: sign_update failed: $ED_ATTRS" >&2; exit 1 ;; esac
DMG_URL="https://github.com/4kulia/agentpad/releases/download/v${VERSION}/$(basename "$DMG")"
bash scripts/appcast.sh "$VERSION" "$DMG_URL" "$ED_ATTRS" > dist/appcast.xml
xmllint --nonet --noout dist/appcast.xml
echo "    dist/appcast.xml → ${DMG_URL}"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo ""
echo "✓ Release image: ${DMG}"
echo "  Publish both ${DMG} and dist/appcast.xml as assets of release v${VERSION}."
echo "  shasum -a 256 ${DMG}"
