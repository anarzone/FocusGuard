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
# Overwrite it with our authoritative iconutil-built icns, then RE-SIGN with
# the real Apple Development identity so the binary keeps its team id.
#
# Why this matters: TCC keys permission grants by (team id + bundle id) for
# Developer-signed apps. If we re-sign ad-hoc by accident, TCC sees a
# brand-new app and the user has to re-grant Accessibility / Screen Recording
# every install. Looking up the identity hash dynamically guarantees we pick
# the correct cert on this machine.
SOURCE_ICNS="FocusGuard/Resources/AppIcon.icns"
if [ -f "$SOURCE_ICNS" ]; then
    cp "$SOURCE_ICNS" "$APP/Contents/Resources/AppIcon.icns"

    IDENTITY_HASH=$(security find-identity -v -p codesigning \
        | awk -F'"' '/Apple Development:/{print substr($0, index($0,"\"")-41, 40); exit}')
    if [ -z "$IDENTITY_HASH" ]; then
        # Fall back to grepping for the SHA-1 prefix on the line.
        IDENTITY_HASH=$(security find-identity -v -p codesigning \
            | grep "Apple Development:" | head -1 | awk '{print $2}')
    fi

    if [ -n "$IDENTITY_HASH" ]; then
        echo "Re-signing with Apple Development cert ($IDENTITY_HASH)…"
        codesign --force --sign "$IDENTITY_HASH" \
            --options runtime \
            --entitlements FocusGuard/Resources/FocusGuard.entitlements \
            "$APP"
    else
        echo "WARNING: no Apple Development identity found — falling back to ad-hoc."
        echo "         TCC grants WILL drop on this install."
        codesign --force --deep --sign - "$APP"
    fi
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
