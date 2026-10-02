#!/usr/bin/env bash
# Build AgentPad as a real macOS .app bundle (no Xcode project required).
#
# What this does:
#   1. swift build -c release
#   2. Assemble dist/AgentPad.app/Contents/{MacOS,Resources,Info.plist,PkgInfo}
#   3. Copy AgentPad + AgentPadHook binaries + the SPM resource bundle into MacOS/
#      (Bundle.module looks next to the executable, which is why fonts +
#      icons live alongside the binary, not under Resources/)
#   4. Generate Info.plist with CFBundleShortVersionString sourced from
#      Sources/AgentPadKit/App/AppInfo.swift's displayVersion — single source
#      of truth, no manual sync
#   5. Adhoc codesign so Gatekeeper doesn't kill it on first launch
#
# Output: dist/AgentPad.app — open it directly or drop into /Applications.
# This is local-distribution-only. Codesigning + notarization for public
# release is a separate step (requires Apple Developer ID).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Pull displayVersion from AppInfo.swift so About + Info.plist stay in sync.
VERSION="$(grep -E 'static let displayVersion' Sources/AgentPadKit/App/AppInfo.swift \
    | sed -E 's/.*= "([^"]+)".*/\1/')"
if [ -z "$VERSION" ]; then
    echo "build-app.sh: failed to extract displayVersion from AppInfo.swift" >&2
    exit 1
fi

BUNDLE_ID="com.4kulia.agentpad"
APP_NAME="AgentPad"
APP="dist/${APP_NAME}.app"

echo "==> Building release config"
swift build -c release

echo "==> Verifying build artifacts"
for f in .build/release/AgentPad .build/release/AgentPadHook .build/release/agentpad-cli; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done
[ -d ".build/release/AgentPad_AgentPadKit.bundle" ] || {
    echo "missing SPM resource bundle: .build/release/AgentPad_AgentPadKit.bundle" >&2
    exit 1
}

echo "==> Assembling ${APP} (v${VERSION})"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"

cp .build/release/AgentPad "${APP}/Contents/MacOS/${APP_NAME}"
cp .build/release/AgentPadHook "${APP}/Contents/MacOS/AgentPadHook"
# Control CLI: the SPM target is already named agentpad-cli, so one name holds
# across dev builds, the bundle, and the Application Support mirror the app
# refreshes at launch (Gatekeeper story in
# ShellIntegration.mirroredHelperBinaryPath).
cp .build/release/agentpad-cli "${APP}/Contents/MacOS/agentpad-cli"
# Bundle.module's first lookup candidate is `Bundle.main.resourceURL`
# (= Contents/Resources/), so the resource bundle has to live there or
# the running .app will silently fall back to .build/release/ on disk.
cp -R .build/release/AgentPad_AgentPadKit.bundle "${APP}/Contents/Resources/"

# App icon — generated from branding/AppIcon.png if present. macOS reads
# .icns from CFBundleIconFile in Info.plist; we synthesize the multi-size
# .iconset via sips, then iconutil packs it. Without a source PNG we ship
# without an icon and the OS falls back to the generic blank-document.
# Pick the largest available source from branding/icons/ — asset catalog
# format names the 1024px slot `icon-512@2x.png`. Fall back to a flat
# `icon-1024.png` (older convention) then to legacy `branding/AppIcon.png`.
for cand in branding/icons/icon-512@2x.png branding/icons/icon-1024.png branding/AppIcon.png; do
    if [ -f "$cand" ]; then
        ICON_SOURCE="$cand"
        break
    fi
done
if [ -f "$ICON_SOURCE" ]; then
    echo "==> Building AppIcon.icns from ${ICON_SOURCE}"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    # Apple's required sizes for an .icns: 16/32/128/256/512 in @1x and @2x.
    # sips resamples cleanly enough for a flat brand mark; for fine detail
    # design, hand-export from Figma/Sketch is preferred.
    for spec in "16:icon_16x16.png" "32:icon_16x16@2x.png" \
                "32:icon_32x32.png" "64:icon_32x32@2x.png" \
                "128:icon_128x128.png" "256:icon_128x128@2x.png" \
                "256:icon_256x256.png" "512:icon_256x256@2x.png" \
                "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
        size="${spec%%:*}"
        name="${spec##*:}"
        sips -z "$size" "$size" "$ICON_SOURCE" --out "${ICONSET}/${name}" >/dev/null
    done
    iconutil -c icns -o "${APP}/Contents/Resources/AppIcon.icns" "$ICONSET"
    rm -rf "$(dirname "$ICONSET")"
    APPLE_ICON_PLIST_KEYS=$(cat <<'KEYS'
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
KEYS
    )
else
    APPLE_ICON_PLIST_KEYS=""
fi

# SPM ships the resource bundle as a flat directory, but its `.bundle` suffix
# triggers codesign's bundle validator → "bundle format invalid". Promote it
# to the canonical macOS bundle layout (Contents/Info.plist +
# Contents/Resources/*) so codesign accepts it. Move every processed resource,
# including localization `.lproj` directories, rather than only fonts/icons.
RES_BUNDLE="${APP}/Contents/Resources/AgentPad_AgentPadKit.bundle"
mkdir -p "${RES_BUNDLE}/Contents/Resources"
find "${RES_BUNDLE}" -mindepth 1 -maxdepth 1 ! -name Contents \
    -exec mv {} "${RES_BUNDLE}/Contents/Resources/" \;
cat > "${RES_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}.resources</string>
    <key>CFBundleName</key>
    <string>AgentPad_AgentPadKit</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
</dict>
</plist>
PLIST

# PkgInfo: 4-byte CFBundlePackageType + 4-byte CFBundleSignature.
# Modern macOS doesn't require it but Finder still uses it for some legacy
# checks; harmless 8 bytes.
printf 'APPL????' > "${APP}/Contents/PkgInfo"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <!-- agentpad:// deep links (resume an agent conversation from outside the
         app). Grammar + handler: Sources/AgentPadKit/App/DeepLink.swift. -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>CFBundleURLName</key>
            <string>${BUNDLE_ID}</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>agentpad</string>
            </array>
        </dict>
    </array>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <!-- TCC attributes a child process's privacy request to the terminal app
         (the "responsible process"). Without the matching usage-description
         key the request is silently denied: no prompt, no System Settings
         entry, tccutil reset can't revive it (issue #31). A terminal can't
         know what its child processes will touch, so declare every category
         they can plausibly hit — same approach as Terminal.app / iTerm2.
         Calendars/Reminders carry both the legacy key and the macOS 14+
         FullAccess/WriteOnly split. NB: adhoc signing pins each TCC grant
         to this build's cdhash, so grants reset on every release — System
         Settings still shows the toggle on, but validation fails; toggle
         off/on (or tccutil reset) to re-grant. Durable fix is Developer ID
         signing (same deferral as notarization). -->
    <key>NSAppleEventsUsageDescription</key>
    <string>AgentPad brings the Terminal or iTerm2 tab of a Claude Code session to the front, and programs running in AgentPad may control other applications.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>A program running in AgentPad wants to access your calendar.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>A program running in AgentPad wants to access your calendar.</string>
    <key>NSCalendarsWriteOnlyAccessUsageDescription</key>
    <string>A program running in AgentPad wants to add events to your calendar.</string>
    <key>NSRemindersUsageDescription</key>
    <string>A program running in AgentPad wants to access your reminders.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>A program running in AgentPad wants to access your reminders.</string>
    <key>NSContactsUsageDescription</key>
    <string>A program running in AgentPad wants to access your contacts.</string>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>A program running in AgentPad wants to access your photo library.</string>
    <key>NSPhotoLibraryAddUsageDescription</key>
    <string>A program running in AgentPad wants to add photos to your photo library.</string>
    <key>NSAppleMusicUsageDescription</key>
    <string>A program running in AgentPad wants to access your music library.</string>
    <key>NSCameraUsageDescription</key>
    <string>A program running in AgentPad wants to use the camera.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>A program running in AgentPad wants to use the microphone.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>A program running in AgentPad wants to capture system audio.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>A program running in AgentPad wants to use speech recognition.</string>
    <key>NSLocationUsageDescription</key>
    <string>A program running in AgentPad wants to access your location.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>A program running in AgentPad wants to access your location.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>A program running in AgentPad wants to find and connect to devices on your local network.</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>A program running in AgentPad wants to use Bluetooth.</string>
    <key>NSMotionUsageDescription</key>
    <string>A program running in AgentPad wants to access motion data.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>A program running in AgentPad wants to access files in your Desktop folder.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>A program running in AgentPad wants to access files in your Documents folder.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>A program running in AgentPad wants to access files in your Downloads folder.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>A program running in AgentPad wants to access files on a removable volume.</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>A program running in AgentPad wants to access files on a network volume.</string>
    <key>NSSystemAdministrationUsageDescription</key>
    <string>A program running in AgentPad wants to administer this computer.</string>
${APPLE_ICON_PLIST_KEYS}
</dict>
</plist>
PLIST

echo "==> Adhoc codesign (skips Gatekeeper kill on first launch)"
# Adhoc signature ('-') is enough for personal-machine launches without a
# Developer ID. Public distribution still needs a real cert + notarytool.
# Sign inside-out: inner resource bundle first, then binaries, then the
# .app — each layer wants its descendants already signed before signing
# itself.
#
# AgentPad: AGENTPAD_SIGN_IDENTITY names a Developer ID certificate for a
# distributable build (scripts/release.sh sets it). That signature carries
# the hardened runtime and a secure timestamp, which notarization requires,
# and the app's entitlements. AGENTPAD_HARDENED=1 applies the hardened
# runtime to an adhoc build, to try its effect without a certificate.
SIGN_IDENTITY="${AGENTPAD_SIGN_IDENTITY:--}"
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
APP_SIGN_FLAGS=("${SIGN_FLAGS[@]}")
if [ "$SIGN_IDENTITY" != "-" ] || [ -n "${AGENTPAD_HARDENED:-}" ]; then
    SIGN_FLAGS+=(--options runtime)
    [ "$SIGN_IDENTITY" = "-" ] || SIGN_FLAGS+=(--timestamp)
    APP_SIGN_FLAGS=("${SIGN_FLAGS[@]}" --entitlements scripts/AgentPad.entitlements)
    echo "    identity: ${SIGN_IDENTITY} (hardened runtime)"
fi
codesign "${SIGN_FLAGS[@]}" "${APP}/Contents/Resources/AgentPad_AgentPadKit.bundle"
codesign "${APP_SIGN_FLAGS[@]}" "${APP}/Contents/MacOS/${APP_NAME}"
codesign "${SIGN_FLAGS[@]}" "${APP}/Contents/MacOS/AgentPadHook"
codesign "${SIGN_FLAGS[@]}" "${APP}/Contents/MacOS/agentpad-cli"
codesign "${APP_SIGN_FLAGS[@]}" "${APP}" 2>&1 | tail -3

echo ""
echo "✓ Built ${APP} (v${VERSION})"
echo "  open ${APP}              # launch"
echo "  cp -R ${APP} /Applications  # install"
