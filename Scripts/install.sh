#!/usr/bin/env bash
# Copies Tokenjar.app into ~/Applications (no admin rights) and relaunches it. make install copies build/Tokenjar.app;
# Homebrew's tokenjar-install-app sets TOKENJAR_APP to the app in its keg.
set -euo pipefail
case "${1:-}" in
  -*)
    echo "error: this command takes no options, only the folder to install into (~/Applications by default)." >&2
    exit 64
    ;;
esac
# Only build/ needs the cd into the repo. With the app named, the script stays in the caller's folder, so a relative
# destination is not resolved inside Homebrew's keg.
if [ -n "${TOKENJAR_APP:-}" ]; then
  APP="$TOKENJAR_APP"
else
  cd "$(dirname "$0")/.."
  APP=build/Tokenjar.app
fi
# Before anything is quit or deleted, so a missing app never leaves the install folder empty.
if [ ! -d "$APP" ]; then
  echo "error: $APP not found. Nothing was changed." >&2
  exit 1
fi
DEST="${1:-$HOME/Applications}"
mkdir -p "$DEST"
# Absolute, because the running app is matched below by the full path it was started with. Through a symlinked folder
# that path may be either spelling, so both are kept.
DEST="$(CDPATH='' cd -- "$DEST" && pwd)"
DEST_RESOLVED="$(CDPATH='' cd -- "$DEST" && pwd -P)"

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
    echo "error: Headroom is still running. Quit it, then run this command again." >&2
    exit 1
  fi
  rm -rf "$OLD"
  echo "Removed $OLD"
fi

# Copying an app onto itself would delete it before the copy starts. Homebrew's opt folder is a link into its Cellar,
# so both sides are compared with links resolved.
APP_RESOLVED="$(CDPATH='' cd -- "$APP" && pwd -P)"
if [ "$APP_RESOLVED" = "$DEST_RESOLVED/Tokenjar.app" ]; then
  echo "error: $APP is already the app in $DEST. Nothing was changed." >&2
  exit 1
fi

# The new copy is made and verified beside the old one first, so a failed copy or check leaves the installed app and the
# running one alone.
NEW="$DEST/.Tokenjar.app.new"
PREVIOUS="$DEST/.Tokenjar.app.old"
rm -rf "$NEW" "$PREVIOUS"
if ! ditto "$APP" "$NEW" || ! codesign --verify --strict "$NEW"; then
  rm -rf "$NEW"
  echo "error: could not copy and verify $APP. The installed app was not changed." >&2
  exit 1
fi

# Only the copy being replaced: matching the name alone would also stop a debug build or a window render.
regex_escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'; }
APP_PATTERN="^($(regex_escape "$DEST")|$(regex_escape "$DEST_RESOLVED"))/Tokenjar\.app/Contents/MacOS/Tokenjar( |\$)"
pkill -f "$APP_PATTERN" 2>/dev/null && sleep 1 || true
if [ -e "$DEST/Tokenjar.app" ]; then
  mv "$DEST/Tokenjar.app" "$PREVIOUS"
fi
if ! mv "$NEW" "$DEST/Tokenjar.app"; then
  [ -e "$PREVIOUS" ] && mv "$PREVIOUS" "$DEST/Tokenjar.app"
  rm -rf "$NEW"
  echo "error: could not move the new app into place. The previous app was put back." >&2
  exit 1
fi
rm -rf "$PREVIOUS"
open "$DEST/Tokenjar.app"
echo "Installed to $DEST/Tokenjar.app"
