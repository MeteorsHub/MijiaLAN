#!/usr/bin/env bash
# Build, sign, notarize and staple a universal release. Does not publish it.
# Required: MIJIALAN_SIGN_IDENTITY (Developer ID Application),
#           MIJIALAN_NOTARY_PROFILE (an existing notarytool Keychain profile).
# Use --package-existing to retry packaging a previously built, signed staging app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${MIJIALAN_VERSION:-0.1.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected a three-part version" >&2; exit 1; }
: "${MIJIALAN_SIGN_IDENTITY:?Set a Developer ID Application signing identity}"
: "${MIJIALAN_NOTARY_PROFILE:?Set an existing notarytool Keychain profile}"
[[ "$MIJIALAN_SIGN_IDENTITY" != - ]] || { echo "Ad hoc signing is not allowed for distribution" >&2; exit 1; }

RELEASE="$ROOT/build/releases/v$VERSION"
STAGING="$RELEASE/staging"
DIST="$RELEASE/dist"
LOGS="$RELEASE/logs"
APP="$STAGING/MijiaLAN.app"
NAME="MijiaLAN-$VERSION-universal"
mkdir -p "$STAGING" "$DIST" "$LOGS"

cd "$ROOT"
case "${1:-}" in
    "")
        swift test -c release --force-resolved-versions > "$LOGS/tests.log" 2>&1
        MIJIALAN_APP_OUTPUT="$APP" MIJIALAN_UNIVERSAL=1 \
            "$ROOT/scripts/build_app.sh" release > "$LOGS/build.log" 2>&1
        ;;
    --package-existing) echo "Packaging the existing staging app: $APP" ;;
    *) echo "Usage: $0 [--package-existing]" >&2; exit 1 ;;
esac
codesign --verify --deep --strict "$APP"
for ARCH in arm64 x86_64; do
    lipo "$APP/Contents/MacOS/MijiaLAN" -verify_arch "$ARCH"
done
[[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" == "$VERSION" ]]
[[ "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" == "${MIJIALAN_BUILD_NUMBER:-1}" ]]
codesign --display --verbose=4 "$APP" 2> "$LOGS/signature.txt"
grep -q '^Authority=Developer ID Application:' "$LOGS/signature.txt"
grep -q 'flags=.*runtime' "$LOGS/signature.txt"
grep -q '^Timestamp=' "$LOGS/signature.txt"

# Staple the app first so the ZIP also works without an online ticket lookup.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$RELEASE/notarization.zip"
xcrun notarytool submit "$RELEASE/notarization.zip" \
    --keychain-profile "$MIJIALAN_NOTARY_PROFILE" --wait --timeout 20m \
    --output-format json > "$LOGS/notarization-app.json"
plutil -extract status raw "$LOGS/notarization-app.json" | grep -qx Accepted
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=4 "$APP" 2> "$LOGS/gatekeeper-app.txt"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME.zip"

# A simple drag-to-Applications disk image, signed and independently notarized.
IMAGE_ROOT="$RELEASE/dmg-root"
mkdir -p "$IMAGE_ROOT"
ditto "$APP" "$IMAGE_ROOT/MijiaLAN.app"
ln -sfn /Applications "$IMAGE_ROOT/Applications"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$IMAGE_ROOT/"
hdiutil create -volname "MijiaLAN $VERSION" -srcfolder "$IMAGE_ROOT" \
    -format UDZO -ov "$DIST/$NAME.dmg"
codesign --force --sign "$MIJIALAN_SIGN_IDENTITY" --timestamp "$DIST/$NAME.dmg"
codesign --verify --strict "$DIST/$NAME.dmg"
xcrun notarytool submit "$DIST/$NAME.dmg" \
    --keychain-profile "$MIJIALAN_NOTARY_PROFILE" --wait --timeout 20m \
    --output-format json > "$LOGS/notarization-dmg.json"
plutil -extract status raw "$LOGS/notarization-dmg.json" | grep -qx Accepted
xcrun stapler staple "$DIST/$NAME.dmg"
xcrun stapler validate "$DIST/$NAME.dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 \
    "$DIST/$NAME.dmg" 2> "$LOGS/gatekeeper-dmg.txt"

cd "$DIST"
shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt
echo "Signed, notarized artifacts: $DIST"
