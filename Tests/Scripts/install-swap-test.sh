#!/usr/bin/env bash
# Exercises Scripts/install.sh against fake signed apps in a temporary folder. pkill, pgrep and open are stubbed, so no
# real Tokenjar is ever quit or launched.
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
INSTALL="$ROOT/Scripts/install.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/install-swap-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

fake_app() {
  local app="$1" marker="$2" id="${3:-com.example.install-swap-test}"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$id</string>
<key>CFBundleExecutable</key><string>Tokenjar</string>
</dict></plist>
PLIST
  printf '#!/bin/sh\n' > "$app/Contents/MacOS/Tokenjar"
  chmod +x "$app/Contents/MacOS/Tokenjar"
  printf '%s' "$marker" > "$app/Contents/Resources/marker"
  codesign --force --sign - "$app" 2>/dev/null
}

# pkill and pgrep report that nothing matched; open succeeds. Every call is logged.
stubs() {
  local bin="$1"
  mkdir -p "$bin"
  : > "$bin/calls.log"
  for tool in pkill pgrep open; do
    local code=1
    [ "$tool" = open ] && code=0
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\nexit %s\n' "$tool" "$bin" "$code" > "$bin/$tool"
    chmod +x "$bin/$tool"
  done
}

# Makes the listed calls to mv (counted from 1) fail without moving anything; every other call is the real mv.
failing_mv() {
  local bin="$1"
  shift
  printf '#!/bin/sh\ncount=$(cat "%s/mv.count" 2>/dev/null || echo 0)\ncount=$((count + 1))\necho "$count" > "%s/mv.count"\ncase " %s " in *" $count "*) exit 1 ;; esac\nexec /bin/mv "$@"\n' \
    "$bin" "$bin" "$*" > "$bin/mv"
  chmod +x "$bin/mv"
}

# Reports Headroom as still running.
headroom_running() { printf '#!/bin/sh\nexit 0\n' > "$1/pgrep"; chmod +x "$1/pgrep"; }

marker_of() { cat "$1/Tokenjar.app/Contents/Resources/marker" 2>/dev/null || echo "<missing>"; }
extras_in() { ls -A "$1" | grep -v '^Tokenjar.app$' || true; }
# A copy moved inside the bundle by mistake breaks its seal, so the signature check also catches nesting.
intact() { codesign --verify --strict "$1/Tokenjar.app" 2>/dev/null; }
called() { grep -q "^$2" "$1/calls.log"; }
not_called() { ! called "$@"; }

check() {
  local name="$1"
  shift
  if "$@"; then
    echo "pass: $name"
  else
    echo "FAIL: $name"
    failures=$((failures + 1))
  fi
}

run_install() {
  local bin="$1" app="$2" dest="$3"
  PATH="$bin:$PATH" TOKENJAR_APP="$app" bash "$INSTALL" "$dest" >"$bin/out.log" 2>&1
}

# A fresh install puts the new app in place and opens it.
t="$WORK/fresh"; stubs "$t/bin"; fake_app "$t/new/Tokenjar.app" new
run_install "$t/bin" "$t/new/Tokenjar.app" "$t/dest"; status=$?
check "fresh install exits 0" [ "$status" -eq 0 ]
check "fresh install puts the new app in place" [ "$(marker_of "$t/dest")" = new ]
check "fresh install opens it" called "$t/bin" "open "

# Replacing an installed copy leaves only the new one, with no staging folders behind.
t="$WORK/replace"; stubs "$t/bin"; fake_app "$t/new/Tokenjar.app" new; fake_app "$t/dest/Tokenjar.app" old
run_install "$t/bin" "$t/new/Tokenjar.app" "$t/dest"; status=$?
check "replace exits 0" [ "$status" -eq 0 ]
check "replace installs the new app" [ "$(marker_of "$t/dest")" = new ]
check "replace quits the copy in the install folder" called "$t/bin" "pkill -f "
check "replace leaves no staging folders" [ -z "$(extras_in "$t/dest")" ]

# A new app that fails its signature check leaves the old app installed and running.
t="$WORK/badsig"; stubs "$t/bin"; fake_app "$t/new/Tokenjar.app" new; fake_app "$t/dest/Tokenjar.app" old
printf 'tampered' > "$t/new/Tokenjar.app/Contents/Resources/marker"
run_install "$t/bin" "$t/new/Tokenjar.app" "$t/dest"; status=$?
check "bad signature exits non-zero" [ "$status" -ne 0 ]
check "bad signature keeps the old app" [ "$(marker_of "$t/dest")" = old ]
check "bad signature never quits the running copy" not_called "$t/bin" "pkill -f "
check "bad signature leaves no staging folders" [ -z "$(extras_in "$t/dest")" ]

# A copy step that fails leaves the old app installed and running.
t="$WORK/copyfail"; stubs "$t/bin"; fake_app "$t/new/Tokenjar.app" new; fake_app "$t/dest/Tokenjar.app" old
printf '#!/bin/sh\nexit 1\n' > "$t/bin/ditto"; chmod +x "$t/bin/ditto"
run_install "$t/bin" "$t/new/Tokenjar.app" "$t/dest"; status=$?
check "failed copy exits non-zero" [ "$status" -ne 0 ]
check "failed copy keeps the old app" [ "$(marker_of "$t/dest")" = old ]
check "failed copy never quits the running copy" not_called "$t/bin" "pkill -f "

# Asked to install an app onto itself, it refuses and changes nothing.
t="$WORK/self"; stubs "$t/bin"; fake_app "$t/dest/Tokenjar.app" old
run_install "$t/bin" "$t/dest/Tokenjar.app" "$t/dest"; status=$?
check "self install exits non-zero" [ "$status" -ne 0 ]
check "self install keeps the app" [ "$(marker_of "$t/dest")" = old ]
check "self install never quits the running copy" not_called "$t/bin" "pkill -f "

# The same app reached through a symlinked folder, as Homebrew's opt links into its Cellar, is still itself.
t="$WORK/selflink"; stubs "$t/bin"; fake_app "$t/cellar/Tokenjar.app" old; ln -s "$t/cellar" "$t/opt"
run_install "$t/bin" "$t/opt/Tokenjar.app" "$t/cellar"; status=$?
check "self install through a link exits non-zero" [ "$status" -ne 0 ]
check "self install through a link keeps the app" [ "$(marker_of "$t/cellar")" = old ]
check "self install through a link never quits the running copy" not_called "$t/bin" "pkill -f "

# Moving the old app aside fails: it stays installed and is reopened, since it was already quit.
t="$WORK/aside"; stubs "$t/bin"; failing_mv "$t/bin" 1; fake_app "$t/new/Tokenjar.app" new; fake_app "$t/dest/Tokenjar.app" old
run_install "$t/bin" "$t/new/Tokenjar.app" "$t/dest"; status=$?
check "failed move aside exits non-zero" [ "$status" -ne 0 ]
check "failed move aside keeps the old app" [ "$(marker_of "$t/dest")" = old ]
check "failed move aside reopens the old app" called "$t/bin" "open "
check "failed move aside says why" grep -q '^error:' "$t/bin/out.log"
check "failed move aside leaves no staging folders" [ -z "$(extras_in "$t/dest")" ]

# Moving the new app in fails: the old app is put back and reopened.
t="$WORK/rollback"; stubs "$t/bin"; failing_mv "$t/bin" 2; fake_app "$t/new/Tokenjar.app" new; fake_app "$t/dest/Tokenjar.app" old
run_install "$t/bin" "$t/new/Tokenjar.app" "$t/dest"; status=$?
check "failed move in exits non-zero" [ "$status" -ne 0 ]
check "failed move in puts the old app back" [ "$(marker_of "$t/dest")" = old ]
check "failed move in reopens the old app" called "$t/bin" "open "
check "failed move in leaves no staging folders" [ -z "$(extras_in "$t/dest")" ]

# A crash between the two renames left only the moved-aside copy: the next run brings it back before anything else.
t="$WORK/crashed"; stubs "$t/bin"; fake_app "$t/new/Tokenjar.app" new; fake_app "$t/dest/.Tokenjar.app.old" old
fake_app "$t/dest/.Tokenjar.app.new" half
printf 'tampered' > "$t/new/Tokenjar.app/Contents/Resources/marker"
run_install "$t/bin" "$t/new/Tokenjar.app" "$t/dest"; status=$?
check "after a crash, a failed install exits non-zero" [ "$status" -ne 0 ]
check "after a crash, the moved-aside app is restored" [ "$(marker_of "$t/dest")" = old ]
check "after a crash, no staging folders are left" [ -z "$(extras_in "$t/dest")" ]
check "after a crash, the restored app is intact" intact "$t/dest"

# If the interrupted install's app cannot be moved back, the script stops and never clears it.
t="$WORK/crashstuck"; stubs "$t/bin"; failing_mv "$t/bin" 1; fake_app "$t/new/Tokenjar.app" new; fake_app "$t/dest/.Tokenjar.app.old" old
run_install "$t/bin" "$t/new/Tokenjar.app" "$t/dest"; status=$?
check "unrecoverable crash leftovers exit non-zero" [ "$status" -ne 0 ]
check "unrecoverable crash leftovers keep the old app aside" [ "$(cat "$t/dest/.Tokenjar.app.old/Contents/Resources/marker" 2>/dev/null)" = old ]
check "unrecoverable crash leftovers say where the app is" grep -q 'Tokenjar.app.old' "$t/bin/out.log"

# Leftovers from a crash after the swap (the app in place plus a stale copy aside) are cleared, never nested.
t="$WORK/stale"; stubs "$t/bin"; fake_app "$t/new/Tokenjar.app" new; fake_app "$t/dest/Tokenjar.app" old
fake_app "$t/dest/.Tokenjar.app.old" older
run_install "$t/bin" "$t/new/Tokenjar.app" "$t/dest"; status=$?
check "stale leftovers: install exits 0" [ "$status" -eq 0 ]
check "stale leftovers: the new app is installed" [ "$(marker_of "$t/dest")" = new ]
check "stale leftovers: nothing is left beside it" [ -z "$(extras_in "$t/dest")" ]
check "stale leftovers: the installed app is intact" intact "$t/dest"

# With a stale copy aside, a failed move in must restore the app that was installed, not the stale one.
t="$WORK/stalerollback"; stubs "$t/bin"; failing_mv "$t/bin" 2; fake_app "$t/new/Tokenjar.app" new
fake_app "$t/dest/Tokenjar.app" old; fake_app "$t/dest/.Tokenjar.app.old" older
run_install "$t/bin" "$t/new/Tokenjar.app" "$t/dest"; status=$?
check "stale leftovers and a failed move in: exits non-zero" [ "$status" -ne 0 ]
check "stale leftovers and a failed move in: the installed app comes back" [ "$(marker_of "$t/dest")" = old ]
check "stale leftovers and a failed move in: the app is not nested or altered" intact "$t/dest"

# Both the move in and the move back fail: the message says where the old app was left.
t="$WORK/doublefail"; stubs "$t/bin"; failing_mv "$t/bin" 2 3; fake_app "$t/new/Tokenjar.app" new; fake_app "$t/dest/Tokenjar.app" old
run_install "$t/bin" "$t/new/Tokenjar.app" "$t/dest"; status=$?
check "double failure exits non-zero" [ "$status" -ne 0 ]
check "double failure keeps the old app aside" [ "$(cat "$t/dest/.Tokenjar.app.old/Contents/Resources/marker" 2>/dev/null)" = old ]
check "double failure names where the old app is" grep -q 'Tokenjar.app.old' "$t/bin/out.log"
check "double failure removes the new copy" [ ! -e "$t/dest/.Tokenjar.app.new" ]

# Headroom still running stops the install before anything is replaced, and the staged copy is removed.
t="$WORK/headroomrunning"; stubs "$t/bin"; headroom_running "$t/bin"; fake_app "$t/new/Tokenjar.app" new
fake_app "$t/dest/Tokenjar.app" old; fake_app "$t/dest/Headroom.app" headroom com.pedromosquera.headroom
run_install "$t/bin" "$t/new/Tokenjar.app" "$t/dest"; status=$?
check "Headroom running exits non-zero" [ "$status" -ne 0 ]
check "Headroom running keeps the installed app" [ "$(marker_of "$t/dest")" = old ]
check "Headroom running keeps Headroom" [ -d "$t/dest/Headroom.app" ]
check "Headroom running removes the staged copy" [ ! -e "$t/dest/.Tokenjar.app.new" ]

# A successful install retires Headroom.
t="$WORK/headroomok"; stubs "$t/bin"; fake_app "$t/new/Tokenjar.app" new; fake_app "$t/dest/Headroom.app" headroom com.pedromosquera.headroom
run_install "$t/bin" "$t/new/Tokenjar.app" "$t/dest"; status=$?
check "install with Headroom present exits 0" [ "$status" -eq 0 ]
check "install with Headroom present removes it" [ ! -e "$t/dest/Headroom.app" ]

# Headroom is retired only once the new app is copied and verified, so a failed copy or check keeps it.
t="$WORK/headroom"; stubs "$t/bin"; fake_app "$t/new/Tokenjar.app" new; fake_app "$t/dest/Headroom.app" headroom com.pedromosquera.headroom
printf 'tampered' > "$t/new/Tokenjar.app/Contents/Resources/marker"
run_install "$t/bin" "$t/new/Tokenjar.app" "$t/dest"; status=$?
check "failed install with Headroom present exits non-zero" [ "$status" -ne 0 ]
check "failed install keeps Headroom" [ -d "$t/dest/Headroom.app" ]

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all install.sh checks passed"
