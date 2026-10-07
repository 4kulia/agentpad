#!/usr/bin/env bash
# Pure feed generation, also usable with fixture metadata. No signing or upload.
set -euo pipefail

VERSION="${1:?version required}"
DMG_URL="${2:?DMG URL required}"
ED_ATTRS="${3:?Sparkle enclosure attributes required}"
RELEASE_NOTES="<sparkle:releaseNotesLink>https://github.com/4kulia/agentpad/releases/tag/v${VERSION}</sparkle:releaseNotesLink>"
if [ -n "${AGENTPAD_RELEASE_NOTES:-}" ]; then
    NOTES_HTML="$(python3 -I "$(dirname "$0")/notes2html.py" "$AGENTPAD_RELEASE_NOTES")"
    # Keep CDATA valid even if a future renderer emits its closing delimiter.
    NOTES_HTML="${NOTES_HTML//\]\]>/\]\]\]\]><!\[CDATA\[>}"
    RELEASE_NOTES="<description><![CDATA[${NOTES_HTML}]]></description>"
fi

cat <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>AgentPad</title>
    <item>
      <title>AgentPad ${VERSION}</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.5</sparkle:minimumSystemVersion>
      ${RELEASE_NOTES}
      <enclosure url="${DMG_URL}" type="application/octet-stream" ${ED_ATTRS} />
    </item>
  </channel>
</rss>
APPCAST
