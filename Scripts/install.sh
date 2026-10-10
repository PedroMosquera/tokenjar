#!/usr/bin/env bash
# Copies build/Headroom.app into ~/Applications (no admin rights) and relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-$HOME/Applications}"
mkdir -p "$DEST"
pkill -x Headroom 2>/dev/null && sleep 1 || true
rm -rf "$DEST/Headroom.app"
ditto build/Headroom.app "$DEST/Headroom.app"
codesign --verify --strict "$DEST/Headroom.app"
open "$DEST/Headroom.app"
echo "Installed to $DEST/Headroom.app"
