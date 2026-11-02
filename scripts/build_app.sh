#!/usr/bin/env bash
# Builds build/MijiaLAN.app: a menu-bar app, ad-hoc signed so macOS can ask for Local Network access.
#
#   scripts/build_app.sh            # release
#   scripts/build_app.sh debug
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
VERSION="0.1.0"
APP="${MIJIALAN_APP_OUTPUT:-$ROOT/build/MijiaLAN.app}"

cd "$ROOT"
swift build -c "$CONFIG" --product MijiaLANApp
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MijiaLANApp" "$APP/Contents/MacOS/MijiaLAN"
# MijiaCore's translation tables; MijiaCore finds them under Contents/Resources.
cp -R "$BIN_DIR/MenuBarMijia_MijiaCore.bundle" "$APP/Contents/Resources/"
cp -R "$BIN_DIR/MijiaLAN_MijiaLAN.bundle" "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/en.lproj" "$ROOT/Resources/zh-Hans.lproj" "$APP/Contents/Resources/"

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
    <string>1</string>
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

codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "$APP"
