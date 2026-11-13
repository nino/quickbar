#!/bin/bash
# Builds Quickbar, installs it to /Applications and (re)starts it.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh release
pkill -x Quickbar 2>/dev/null && sleep 0.5 || true
rm -rf /Applications/Quickbar.app
cp -R build/Quickbar.app /Applications/Quickbar.app
open /Applications/Quickbar.app
echo "Installed and started /Applications/Quickbar.app"
