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

echo "Stopping any running instance…"
pkill -f "FocusGuard.app/Contents/MacOS/FocusGuard" 2>/dev/null || true
sleep 1

echo "Installing to $DEST…"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo "Launching…"
open "$DEST"

echo "Installed FocusGuard to $DEST"
