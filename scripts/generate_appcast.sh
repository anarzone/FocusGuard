#!/usr/bin/env bash
#
# Generates a single-item Sparkle appcast.xml for a release and writes it to
# <out_path>. Shared by scripts/release.sh (local) and the release GitHub
# Action. Sparkle picks the newest <item> in the feed, so a one-item appcast
# pointing at the latest release is sufficient to drive updates.
#
# Usage:
#   generate_appcast.sh <zip> <marketing_version> <build_number> <download_url> <out_path>
#
# Environment:
#   SIGN_UPDATE   path to Sparkle's sign_update binary (required). After a build
#                 it lives under <derivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin.
#   ED_KEY_FILE   path to the EdDSA private key file (optional). When set, the
#                 key is read from this file (CI, key comes from a secret). When
#                 unset, sign_update reads the key from the login keychain
#                 (local releases, where generate_keys stored it).
#
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <zip> <marketing_version> <build_number> <download_url> <out_path>" >&2
    exit 1
fi

ZIP="$1"; VERSION="$2"; BUILD="$3"; URL="$4"; OUT="$5"

[ -f "$ZIP" ] || { echo "zip not found: $ZIP" >&2; exit 1; }
[ -n "${SIGN_UPDATE:-}" ] || { echo "SIGN_UPDATE env not set" >&2; exit 1; }
[ -x "$SIGN_UPDATE" ] || { echo "sign_update not executable: $SIGN_UPDATE" >&2; exit 1; }

# sign_update prints: sparkle:edSignature="..." length="..."  — paste verbatim
# into the enclosure tag.
if [ -n "${ED_KEY_FILE:-}" ]; then
    SIG_ATTRS=$("$SIGN_UPDATE" --ed-key-file "$ED_KEY_FILE" "$ZIP")
else
    SIG_ATTRS=$("$SIGN_UPDATE" "$ZIP")
fi
case "$SIG_ATTRS" in
    *edSignature=*length=*) : ;;
    *) echo "unexpected sign_update output: $SIG_ATTRS" >&2; exit 1 ;;
esac

PUBDATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>FocusGuard</title>
    <link>https://anarzone.github.io/FocusGuard/appcast.xml</link>
    <description>Updates for FocusGuard.</description>
    <language>en</language>
    <item>
      <title>FocusGuard $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>FocusGuard $VERSION. See the <a href="https://github.com/anarzone/FocusGuard/releases/tag/v$VERSION">release notes</a>.</p>]]></description>
      <enclosure url="$URL" type="application/octet-stream" $SIG_ATTRS />
    </item>
  </channel>
</rss>
XML

echo "Wrote appcast to $OUT (version $VERSION, build $BUILD)"
