#!/usr/bin/env bash
# Builds build/MijiaLAN.app, ad hoc signed for local use by default.
#
#   scripts/build_app.sh            # release
#   scripts/build_app.sh debug
# Set MIJIALAN_UNIVERSAL=1 for Apple Silicon + Intel, and MIJIALAN_SIGN_IDENTITY
# to a Developer ID Application identity for timestamped hardened runtime signing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
VERSION="${MIJIALAN_VERSION:-0.1.0}"
BUILD_NUMBER="${MIJIALAN_BUILD_NUMBER:-1}"
SIGN_IDENTITY="${MIJIALAN_SIGN_IDENTITY:--}"
APP="${MIJIALAN_APP_OUTPUT:-$ROOT/build/MijiaLAN.app}"

[[ "$CONFIG" == release || "$CONFIG" == debug ]] || { echo "Expected release or debug" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected a three-part version" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo "Expected a positive build number" >&2; exit 1; }
[[ "$APP" == /*.app ]] || { echo "App output must be an absolute .app path" >&2; exit 1; }

cd "$ROOT"
BUILD_ARGS=(-c "$CONFIG" --force-resolved-versions --product MijiaLANApp)
if [[ "${MIJIALAN_UNIVERSAL:-0}" == 1 ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MijiaLANApp" "$APP/Contents/MacOS/MijiaLAN"
# MijiaCore's translation tables; MijiaCore finds them under Contents/Resources.
cp -R "$BIN_DIR/MenuBarMijia_MijiaCore.bundle" "$APP/Contents/Resources/"
cp -R "$BIN_DIR/MijiaLAN_MijiaLAN.bundle" "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/en.lproj" "$ROOT/Resources/zh-Hans.lproj" "$APP/Contents/Resources/"
# Ship the original notices, including notices for bundled third party C code.
mkdir -p "$APP/Contents/Resources/Licenses/MijiaLAN"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Licenses/MijiaLAN/"
cp "$ROOT/PRIVACY.md" "$ROOT/PRIVACY.en.md" "$APP/Contents/Resources/"
while IFS= read -r -d '' NOTICE; do
    RELATIVE="${NOTICE#"$ROOT/"}"
    RELATIVE="${RELATIVE#.build/checkouts/}"
    DESTINATION="$APP/Contents/Resources/Licenses/$RELATIVE"
    mkdir -p "$(dirname "$DESTINATION")"
    cp "$NOTICE" "$DESTINATION"
done < <(find "$ROOT/.build/checkouts" "$ROOT/Vendor/hap-swift" -type f \
    \( -iname 'LICENSE*' -o -iname 'NOTICE*' -o -iname 'COPYING*' -o -iname 'PATENTS*' \
    -o -name 'CNIOSHA1.h' -o -name 'cpp_magic.h' \) \
    -not -path '*/.git/*' -print0)

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>zh-Hans</string></array>
    <key>CFBundleDisplayName</key>
    <string>MijiaLAN</string>
    <key>CFBundleExecutable</key>
    <string>MijiaLAN</string>
    <key>CFBundleIdentifier</key>
    <string>com.mijialan.MijiaLAN</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MijiaLAN</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>MijiaLAN controls Mijia Wi-Fi devices directly over your local network and provides a HomeKit bridge for the Home app on your iPhone.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_hap._tcp</string>
        <string>_miio._udp</string>
    </array>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"
if [[ "${MIJIALAN_UNIVERSAL:-0}" == 1 ]]; then
    for ARCH in arm64 x86_64; do
        lipo "$APP/Contents/MacOS/MijiaLAN" -verify_arch "$ARCH"
    done
fi
if [[ "$CONFIG" == release ]]; then
    strip -S "$APP/Contents/MacOS/MijiaLAN"
fi
if [[ "$SIGN_IDENTITY" == - ]]; then
    codesign --force --sign - --timestamp=none "$APP"
else
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "$APP"
