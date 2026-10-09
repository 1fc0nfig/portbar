#!/usr/bin/env bash
# Prints the Sparkle appcast for a release: scripts/write-appcast.sh <version> <zip> [notes.md]
#
# Signs the zip with the EdDSA key from SPARKLE_KEY_FILE, or from the login Keychain
# (account "portbar") when it is not set. DOWNLOAD_BASE changes where the zip is served,
# for a local test.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$1"
ZIP="$2"
NOTES="${3:-}"
BASE="${DOWNLOAD_BASE:-https://github.com/1fc0nfig/portbar/releases/download/portbar-v$VERSION}"

SIGN="$(find .build/artifacts -path '*/bin/sign_update' -type f | head -n1)"
[ -n "$SIGN" ] || { echo "missing sign_update: run swift build first" >&2; exit 1; }
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
  ATTRS="$("$SIGN" --ed-key-file "$SPARKLE_KEY_FILE" "$ZIP")"
else
  ATTRS="$("$SIGN" --account portbar "$ZIP")"
fi

DESCRIPTION=""
if [ -n "$NOTES" ] && [ -s "$NOTES" ]; then
  DESCRIPTION="      <description sparkle:format=\"markdown\"><![CDATA[$(sed 's/]]>/]]]]><![CDATA[>/g' "$NOTES")]]></description>"
fi

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>portbar</title>
    <item>
      <title>portbar $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/1fc0nfig/portbar/releases/tag/portbar-v$VERSION</sparkle:fullReleaseNotesLink>
$DESCRIPTION
      <enclosure url="$BASE/portbar-$VERSION.zip" type="application/octet-stream" $ATTRS/>
    </item>
  </channel>
</rss>
XML
