#!/usr/bin/env bash
# Copies build/Tokenjar.app into ~/Applications (no admin rights) and relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-$HOME/Applications}"
mkdir -p "$DEST"

# The app used to be Headroom. Tokenjar moves its data only once Headroom has quit, so quit it and remove its bundle,
# but only a bundle that carries Headroom's own bundle id.
OLD="$DEST/Headroom.app"
if [ -d "$OLD" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OLD/Contents/Info.plist" 2>/dev/null)" = "com.pedromosquera.headroom" ]; then
  pkill -x Headroom 2>/dev/null || true
  for _ in $(seq 50); do
    pgrep -x Headroom >/dev/null || break
    sleep 0.1
  done
  if pgrep -x Headroom >/dev/null; then
    echo "error: Headroom is still running. Quit it, then run make install again." >&2
    exit 1
  fi
  rm -rf "$OLD"
  echo "Removed $OLD"
fi

pkill -x Tokenjar 2>/dev/null && sleep 1 || true
rm -rf "$DEST/Tokenjar.app"
ditto build/Tokenjar.app "$DEST/Tokenjar.app"
codesign --verify --strict "$DEST/Tokenjar.app"
open "$DEST/Tokenjar.app"
echo "Installed to $DEST/Tokenjar.app"
