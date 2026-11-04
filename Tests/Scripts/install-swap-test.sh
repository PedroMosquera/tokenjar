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
  local app="$1" marker="$2"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.install-swap-test</string>
<key>CFBundleExecutable</key><string>Tokenjar</string>
</dict></plist>
PLIST
  printf '#!/bin/sh\n' > "$app/Contents/MacOS/Tokenjar"
  chmod +x "$app/Contents/MacOS/Tokenjar"
  printf '%s' "$marker" > "$app/Contents/Resources/marker"
  codesign --force --sign - "$app" 2>/dev/null
}

stubs() {
  local bin="$1"
  mkdir -p "$bin"
  # pkill and pgrep report that nothing matched; open succeeds.
  for tool in pkill pgrep open; do
    local code=1
    [ "$tool" = open ] && code=0
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\nexit %s\n' "$tool" "$bin" "$code" > "$bin/$tool"
    chmod +x "$bin/$tool"
  done
}

marker_of() { cat "$1/Tokenjar.app/Contents/Resources/marker" 2>/dev/null || echo "<missing>"; }

check() {
  local name="$1" condition="$2"
  if eval "$condition"; then
    echo "pass: $name"
  else
    echo "FAIL: $name ($condition)"
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
check "fresh install exits 0" "[ $status -eq 0 ]"
check "fresh install puts the new app in place" "[ \"\$(marker_of $t/dest)\" = new ]"
check "fresh install opens it" "grep -q '^open ' $t/bin/calls.log"

# Replacing an installed copy leaves only the new one, with no staging folders behind.
t="$WORK/replace"; stubs "$t/bin"; fake_app "$t/new/Tokenjar.app" new; fake_app "$t/dest/Tokenjar.app" old
run_install "$t/bin" "$t/new/Tokenjar.app" "$t/dest"; status=$?
check "replace exits 0" "[ $status -eq 0 ]"
check "replace installs the new app" "[ \"\$(marker_of $t/dest)\" = new ]"
check "replace quits the copy in the install folder" "grep -q '^pkill -f ' $t/bin/calls.log"
check "replace leaves no staging folders" "[ -z \"\$(ls -A $t/dest | grep -v '^Tokenjar.app$')\" ]"

# A new app that fails its signature check leaves the old app installed and running.
t="$WORK/badsig"; stubs "$t/bin"; fake_app "$t/new/Tokenjar.app" new; fake_app "$t/dest/Tokenjar.app" old
printf 'tampered' > "$t/new/Tokenjar.app/Contents/Resources/marker"
run_install "$t/bin" "$t/new/Tokenjar.app" "$t/dest"; status=$?
check "bad signature exits non-zero" "[ $status -ne 0 ]"
check "bad signature keeps the old app" "[ \"\$(marker_of $t/dest)\" = old ]"
check "bad signature never quits the running copy" "! grep -q '^pkill -f ' $t/bin/calls.log 2>/dev/null"
check "bad signature leaves no staging folders" "[ -z \"\$(ls -A $t/dest | grep -v '^Tokenjar.app$')\" ]"

# A copy that fails partway leaves the old app installed and running.
t="$WORK/copyfail"; stubs "$t/bin"; fake_app "$t/new/Tokenjar.app" new; fake_app "$t/dest/Tokenjar.app" old
printf '#!/bin/sh\nexit 1\n' > "$t/bin/ditto"; chmod +x "$t/bin/ditto"
run_install "$t/bin" "$t/new/Tokenjar.app" "$t/dest"; status=$?
check "failed copy exits non-zero" "[ $status -ne 0 ]"
check "failed copy keeps the old app" "[ \"\$(marker_of $t/dest)\" = old ]"
check "failed copy never quits the running copy" "! grep -q '^pkill -f ' $t/bin/calls.log 2>/dev/null"

# Asked to install an app onto itself, it refuses and changes nothing.
t="$WORK/self"; stubs "$t/bin"; fake_app "$t/dest/Tokenjar.app" old
run_install "$t/bin" "$t/dest/Tokenjar.app" "$t/dest"; status=$?
check "self install exits non-zero" "[ $status -ne 0 ]"
check "self install keeps the app" "[ \"\$(marker_of $t/dest)\" = old ]"
check "self install never quits the running copy" "! grep -q '^pkill -f ' $t/bin/calls.log 2>/dev/null"

# The same app reached through a symlinked folder, as Homebrew's opt links into its Cellar, is still itself.
t="$WORK/selflink"; stubs "$t/bin"; fake_app "$t/cellar/Tokenjar.app" old; ln -s "$t/cellar" "$t/opt"
run_install "$t/bin" "$t/opt/Tokenjar.app" "$t/cellar"; status=$?
check "self install through a link exits non-zero" "[ $status -ne 0 ]"
check "self install through a link keeps the app" "[ \"\$(marker_of $t/cellar)\" = old ]"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all install.sh checks passed"
