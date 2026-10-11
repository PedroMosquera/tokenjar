#!/usr/bin/env bash
# Copies build/Tokenjar.app into ~/Applications (no admin rights) and relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-$HOME/Applications}"
mkdir -p "$DEST"
pkill -x Tokenjar 2>/dev/null && sleep 1 || true
rm -rf "$DEST/Tokenjar.app"
ditto build/Tokenjar.app "$DEST/Tokenjar.app"
codesign --verify --strict "$DEST/Tokenjar.app"
open "$DEST/Tokenjar.app"
echo "Installed to $DEST/Tokenjar.app"
