#!/usr/bin/env bash
#
# Cuts a new FocusGuard release:
#   1. Builds Release configuration
#   2. Zips the .app
#   3. Creates a git tag and GitHub Release with the zip attached
#   4. Updates the homebrew-focusguard tap with new version + sha256
#
# Usage:  ./scripts/release.sh <version>
#         e.g.  ./scripts/release.sh 0.2.0
#
# Prerequisites:
#   - gh CLI authenticated (`gh auth status`)
#   - Working tree clean (no uncommitted changes)
#   - Release notes prepared (you'll be prompted via $EDITOR)
#
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <version>  (e.g. $0 0.2.0)" >&2
    exit 1
fi

VERSION="$1"
TAG="v$VERSION"
ZIP_NAME="FocusGuard-$TAG.zip"

cd "$(dirname "$0")/.."

# Monotonic build number for CFBundleVersion + Sparkle's sparkle:version. Both
# the shipped app and the appcast use this same value so Sparkle can compare
# versions. (CI uses github.run_number for the same purpose.)
BUILD=$(git rev-list --count HEAD)

# ----- preflight -----
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Working tree has uncommitted changes. Commit or stash first." >&2
    exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Tag $TAG already exists." >&2
    exit 1
fi
command -v xcodegen >/dev/null || { echo "brew install xcodegen" >&2; exit 1; }
command -v gh       >/dev/null || { echo "brew install gh" >&2; exit 1; }

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# ----- build -----
echo "==> Generating project + building Release…"
xcodegen generate >/dev/null
rm -rf build/release
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
[ -d "$APP" ] || { echo "Build did not produce $APP" >&2; exit 1; }

# Bundle the authoritative iconutil-built icns + re-sign with the real
# Apple Development cert so TCC grants persist across installs. See
# install.sh for the full rationale.
SOURCE_ICNS="FocusGuard/Resources/AppIcon.icns"
if [ -f "$SOURCE_ICNS" ]; then
    cp "$SOURCE_ICNS" "$APP/Contents/Resources/AppIcon.icns"
    IDENTITY_HASH=$(security find-identity -v -p codesigning \
        | grep "Apple Development:" | head -1 | awk '{print $2}')
    [ -n "$IDENTITY_HASH" ] || { echo "no Apple Development cert found" >&2; exit 1; }
    echo "==> Re-signing with $IDENTITY_HASH…"
    codesign --force --sign "$IDENTITY_HASH" \
        --options runtime \
        --entitlements FocusGuard/Resources/FocusGuard.entitlements \
        "$APP"
fi

mkdir -p build
ZIP="build/$ZIP_NAME"
rm -f "$ZIP"
echo "==> Zipping…"
ditto -c -k --keepParent "$APP" "$ZIP"

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "==> sha256: $SHA"

# ----- tag + release -----
echo "==> Creating tag $TAG…"
git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"

echo "==> Creating GitHub Release…"
gh release create "$TAG" "$ZIP" \
    --title "$TAG" \
    --notes "FocusGuard $TAG

\`\`\`sh
brew upgrade --cask anarzone/tap/focusguard
\`\`\`

(or first-time: \`brew install --cask anarzone/tap/focusguard\`)"

# ----- Sparkle appcast -----
# Sign the zip + render appcast.xml, then publish it to the gh-pages branch so
# https://anarzone.github.io/FocusGuard/appcast.xml serves the new version to
# in-app updaters. The private EdDSA key is read from the login keychain
# (stored there by Sparkle's generate_keys). See docs/RELEASING.md.
echo "==> Generating + publishing Sparkle appcast…"
SIGN_UPDATE="build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || { echo "sign_update missing at $SIGN_UPDATE" >&2; exit 1; }
DOWNLOAD_URL="https://github.com/anarzone/FocusGuard/releases/download/$TAG/$ZIP_NAME"
SIGN_UPDATE="$SIGN_UPDATE" scripts/generate_appcast.sh \
    "$ZIP" "$VERSION" "$BUILD" "$DOWNLOAD_URL" build/appcast.xml

PAGES_DIR=$(mktemp -d)
ORIGIN_URL=$(git remote get-url origin)
if git ls-remote --exit-code --heads "$ORIGIN_URL" gh-pages >/dev/null 2>&1; then
    git clone --quiet --branch gh-pages "$ORIGIN_URL" "$PAGES_DIR"
else
    git clone --quiet "$ORIGIN_URL" "$PAGES_DIR"
    ( cd "$PAGES_DIR" && git checkout --orphan gh-pages && git rm -rf . >/dev/null 2>&1 || true )
fi
cp build/appcast.xml "$PAGES_DIR/appcast.xml"
touch "$PAGES_DIR/.nojekyll"   # serve appcast.xml verbatim, skip Jekyll
(
    cd "$PAGES_DIR"
    git add appcast.xml .nojekyll
    git commit -q -m "appcast: FocusGuard $VERSION" || echo "    (appcast unchanged)"
    git push --quiet origin gh-pages
)
rm -rf "$PAGES_DIR"

# ----- update tap -----
TAP_DIR="${TAP_DIR:-$HOME/Projects/Own/homebrew-tap}"
if [ ! -d "$TAP_DIR" ]; then
    echo "==> Cloning tap into $TAP_DIR…"
    git clone "git@github.com:anarzone/homebrew-tap.git" "$TAP_DIR"
fi

CASK="$TAP_DIR/Casks/focusguard.rb"
echo "==> Updating $CASK…"
# Portable in-place sed (BSD on macOS).
sed -i '' "s|version \".*\"|version \"$VERSION\"|" "$CASK"
sed -i '' "s|sha256 \".*\"|sha256 \"$SHA\"|"      "$CASK"

(
    cd "$TAP_DIR"
    git add Casks/focusguard.rb
    git commit -m "focusguard: bump to $VERSION"
    git push origin main
)

echo ""
echo "Released $TAG"
echo "    Cask SHA: $SHA"
echo ""
echo "Test the install:"
echo "    brew upgrade --cask anarzone/tap/focusguard"
