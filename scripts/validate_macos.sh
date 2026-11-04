#!/usr/bin/env bash
# Run from a pulled checkout on a Mac. Never changes tracked source, commits or pushes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'This validation requires macOS.' >&2; exit 2; }
cd "$ROOT"
git diff --quiet && git diff --cached --quiet || { echo 'Use a clean checkout to validate an exact remote commit.' >&2; exit 2; }
REPORT="${1:-$(mktemp -d /tmp/mijialan-validation.XXXXXX)}"
mkdir -p "$REPORT"
exec > >(tee "$REPORT/validation.log") 2>&1
printf 'Validation report: %s\n' "$REPORT"
printf 'Commit: '; git rev-parse HEAD
sw_vers
xcode-select -p
swift --version
node --version
npm --version
swift build --force-resolved-versions --product mijia-lan
swift build --force-resolved-versions --product MijiaLANApp
swift test --force-resolved-versions
npm ci --prefix MatterBridge
npm test --prefix MatterBridge
bash scripts/build_app.sh debug
python3 scripts/app_icon.py --check --app build/MijiaLAN.app
codesign --verify --deep --strict build/MijiaLAN.app
printf '\nPASS: build, Swift tests, Matter tests, full App packaging, application icon and signature verification.\n'
printf 'App: %s/build/MijiaLAN.app\n' "$ROOT"
printf 'UI interaction and hardware pairing still require a separate validation.\n'
