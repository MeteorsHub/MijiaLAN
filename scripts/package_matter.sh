#!/usr/bin/env bash
# Called by build_app.sh before signing. Bundle both architectures, independent of the user's Node installation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Expected app bundle path}"
NODE_VERSION=22.22.0
CACHE="$ROOT/build/matter-downloads"
mkdir -p "$CACHE" "$APP/Contents/Resources/MatterRuntime"
npm ci --prefix "$ROOT/MatterBridge" --omit=dev
mkdir -p "$APP/Contents/Resources/MatterBridge"
cp -R "$ROOT/MatterBridge/src" "$ROOT/MatterBridge/node_modules" "$ROOT/MatterBridge/package.json" "$APP/Contents/Resources/MatterBridge/"
curl --fail --location --proto '=https' "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt" -o "$CACHE/SHASUMS256.txt"
for ARCH in arm64 x64; do
    ARCHIVE="node-v$NODE_VERSION-darwin-$ARCH.tar.gz"
    curl --fail --location --proto '=https' "https://nodejs.org/dist/v$NODE_VERSION/$ARCHIVE" -o "$CACHE/$ARCHIVE"
    (cd "$CACHE"; awk -v file="$ARCHIVE" '$2 == file' SHASUMS256.txt > "$ARCHIVE.sha256"; test -s "$ARCHIVE.sha256"; shasum -a 256 -c "$ARCHIVE.sha256")
    mkdir -p "$APP/Contents/Resources/MatterRuntime/$ARCH"
    tar -xzf "$CACHE/$ARCHIVE" --strip-components=1 -C "$APP/Contents/Resources/MatterRuntime/$ARCH" "node-v$NODE_VERSION-darwin-$ARCH/bin/node" "node-v$NODE_VERSION-darwin-$ARCH/LICENSE"
done
