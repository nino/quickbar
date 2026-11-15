#!/bin/bash
# Builds Quickbar, installs it and (re)starts it. Admins get /Applications;
# other users can't write there, so they get ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

if id -Gn | tr ' ' '\n' | grep -qx admin; then
    dest_dir=/Applications
else
    dest_dir="$HOME/Applications"
fi
dest="$dest_dir/Quickbar.app"

scripts/build-app.sh release
pkill -x Quickbar 2>/dev/null && sleep 0.5 || true
mkdir -p "$dest_dir"
rm -rf "$dest"
cp -R build/Quickbar.app "$dest"
open "$dest"
echo "Installed and started $dest"
