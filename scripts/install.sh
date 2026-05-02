#!/usr/bin/env bash
#
# Builds FocusGuard in Release configuration and installs it to /Applications,
# replacing any existing copy. Use after changing source code so the running
# /Applications/FocusGuard.app picks up your changes.
#
# Usage:  ./scripts/install.sh
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

echo "Building Release…"
xcodebuild \
    -project FocusGuard.xcodeproj \
    -scheme FocusGuard \
    -configuration Release \
    -destination 'platform=macOS' \
    -allowProvisioningUpdates \
    -derivedDataPath build/release \
    -quiet \
    build

APP="build/release/Build/Products/Release/FocusGuard.app"
DEST="/Applications/FocusGuard.app"

if [ ! -d "$APP" ]; then
    echo "Build failed: $APP not found" >&2
    exit 1
fi

# xcodebuild emits an asset-catalog-compiled AppIcon.icns that's missing
# chunks ic08/09/10/14 — large-size renditions Quick Look + Finder need.
# We overwrite it with our authoritative iconutil-built icns from source.
SOURCE_ICNS="FocusGuard/Resources/AppIcon.icns"
if [ -f "$SOURCE_ICNS" ]; then
    cp "$SOURCE_ICNS" "$APP/Contents/Resources/AppIcon.icns"
    # Re-sign so the bundle hash matches the new icns.
    codesign --force --sign "Apple Development: $(whoami)" \
        --options runtime \
        --entitlements FocusGuard/Resources/FocusGuard.entitlements \
        "$APP" 2>/dev/null || \
    codesign --force --deep --sign - "$APP"
fi

echo "Stopping any running instance…"
pkill -f "FocusGuard.app/Contents/MacOS/FocusGuard" 2>/dev/null || true
sleep 1

echo "Installing to $DEST…"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

# Re-register so Finder/Spotlight pick up the new icon.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -f -r -trusted "$DEST" 2>/dev/null || true

echo "Launching…"
open "$DEST"

echo "Installed FocusGuard to $DEST"
