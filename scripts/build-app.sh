#!/bin/bash
# Builds build/Quickbar.app. Usage: scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Quickbar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Quickbar" "$APP/Contents/MacOS/Quickbar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Sign with a stable identity when there is one: macOS ties privacy grants
# (Documents, Desktop, clipboard) to the signature, and an ad-hoc signature
# changes on every build, which would re-prompt each time.
IDENTITY="${QUICKBAR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})" | sed -E 's/\(signed: [^)]*\(/(signed: (/'
