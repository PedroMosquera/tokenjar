#!/usr/bin/env bash
# Copies build/Tokenjar.app into ~/Applications (no admin rights) and relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-$HOME/Applications}"
mkdir -p "$DEST"
# Absolute, because the running app is matched below by the full path LaunchServices started it with.
DEST="$(CDPATH='' cd -- "$DEST" && pwd)"

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

# Only the copy being replaced: matching the name alone would also stop a debug build or a window render.
APP_EXECUTABLE="$DEST/Tokenjar.app/Contents/MacOS/Tokenjar"
APP_PATTERN="^$(printf '%s' "$APP_EXECUTABLE" | sed 's/[][\.*^$+?(){}|]/\\&/g')( |\$)"
pkill -f "$APP_PATTERN" 2>/dev/null && sleep 1 || true
rm -rf "$DEST/Tokenjar.app"
ditto build/Tokenjar.app "$DEST/Tokenjar.app"
codesign --verify --strict "$DEST/Tokenjar.app"
open "$DEST/Tokenjar.app"
echo "Installed to $DEST/Tokenjar.app"
