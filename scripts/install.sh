#!/usr/bin/env bash
#
# Builds FocusGuard in Release configuration and installs it to /Applications,
# replacing any existing copy. Use after changing source code so the running
# /Applications/FocusGuard.app picks up your changes.
#
# Usage:  ./scripts/install.sh [version]
#
# The build is stamped like a release (see release.sh) so Sparkle never sees
# a local install as older than the published appcast and "updates" it back:
#   CFBundleShortVersionString = [version], default: latest v* tag
#   CFBundleVersion            = commit count, same counter release.sh uses
#
set -euo pipefail

cd "$(dirname "$0")/.."

# Generate Xcode project if missing (or always-fresh — cheap operation).
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen not installed. Run: brew install xcodegen" >&2
    exit 1
fi
xcodegen generate >/dev/null

# Make sure we use a real Xcode, not just CLT.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

LATEST_TAG=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo "v0.0.0")
VERSION="${1:-${LATEST_TAG#v}}"
BUILD=$(git rev-list --count HEAD)

echo "Building Release $VERSION ($BUILD)…"
xcodebuild \
    -project FocusGuard.xcodeproj \
    -scheme FocusGuard \
    -configuration Release \
    -destination 'platform=macOS' \
    -allowProvisioningUpdates \
    -derivedDataPath build/release \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    -quiet \
    build

APP="build/release/Build/Products/Release/FocusGuard.app"
DEST="/Applications/FocusGuard.app"

if [ ! -d "$APP" ]; then
    echo "Build failed: $APP not found" >&2
    exit 1
fi

echo "Stopping any running instance…"
pkill -f "FocusGuard.app/Contents/MacOS/FocusGuard" 2>/dev/null || true
sleep 1

echo "Installing to $DEST…"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# Every build registers its copy of the app with LaunchServices (Xcode's
# DerivedData, build/, test runs), and LaunchServices may then open one of
# those instead of this one from Spotlight, a focusguard:// link or a
# widget: an old build, or one that can't open the current store. Forget
# every copy but this one.
"$LSREGISTER" -dump 2>/dev/null \
    | sed -n 's|^path: *\(.*/FocusGuard\.app\) (0x[0-9a-f]*)$|\1|p' \
    | sort -u \
    | while IFS= read -r copy; do
        [ "$copy" = "$DEST" ] || "$LSREGISTER" -u "$copy" 2>/dev/null || true
    done

# Re-register so Finder/Spotlight pick up the new icon.
"$LSREGISTER" -f -r -trusted "$DEST" 2>/dev/null || true

echo "Launching…"
open "$DEST"

echo "Installed FocusGuard $VERSION ($BUILD) to $DEST"
