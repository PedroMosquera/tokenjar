#!/usr/bin/env bash
# Exercises Scripts/get.sh against a fake release archive. curl, swift and xcode-select are stubbed, so nothing is
# downloaded and nothing is built or installed for real.
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
GET="$ROOT/Scripts/get.sh"
# Through cd, so a TMPDIR ending in a slash does not leave // in paths that get.sh prints normalized.
WORK="$(CDPATH='' cd -- "$(mktemp -d "${TMPDIR:-/tmp}/get-stage-test.XXXXXX")" && pwd)"
trap 'rm -rf "$WORK"' EXIT
failures=0

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

# A source tree whose make app builds a marked app and make install only records that it ran.
fake_archive() {
  local t="$1" src="$1/src/tokenjar-0.9.0"
  mkdir -p "$src/Scripts"
  printf '#!/usr/bin/env bash\n# the new install.sh\n' > "$src/Scripts/install.sh"
  cat > "$src/Makefile" <<'MAKE'
app:
	@if [ -n "$$FAIL_BUILD" ]; then echo "build broke" >&2; exit 1; fi
	mkdir -p build/Tokenjar.app/Contents
	printf new > build/Tokenjar.app/Contents/marker
	echo "make app" >> "$$CALLS"

install:
	echo "make install $(INSTALL_DIR)" >> "$$CALLS"
MAKE
  tar -czf "$t/archive.tar.gz" -C "$t/src" tokenjar-0.9.0
}

stubs() {
  local t="$1" bin="$1/bin"
  mkdir -p "$bin" "$t/home" "$t/tmp"
  : > "$t/calls.log"
  printf '#!/bin/sh\necho /Library/Developer/CommandLineTools\n' > "$bin/xcode-select"
  printf '#!/bin/sh\necho "swift-driver version: 1.0 Apple Swift version 6.2 (swiftlang-6.2)"\n' > "$bin/swift"
  printf '#!/bin/sh\necho "curl $*" >> "%s/calls.log"\ncat "%s/archive.tar.gz"\n' "$t" "$t" > "$bin/curl"
  chmod +x "$bin/xcode-select" "$bin/swift" "$bin/curl"
}

setup() {
  local t="$WORK/$1"
  mkdir -p "$t"
  fake_archive "$t"
  stubs "$t"
  echo "$t"
}

run_get() {
  local t="$1"
  shift
  env PATH="$t/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$t/home" TMPDIR="$t/tmp" CALLS="$t/calls.log" TOKENJAR_VERSION=0.9.0 "$@" \
    bash "$GET" >"$t/out.log" 2>&1
}

called() { grep -q "^$2" "$1/calls.log"; }
not_called() { ! called "$@"; }

# Stage mode builds and copies the app and install.sh, and installs nothing. The folder has a space, as
# Application Support does.
t="$(setup stage)"
stage="$t/Application Support/update"
run_get "$t" TOKENJAR_STAGE_DIR="$stage"
status=$?
check "stage mode exits 0" [ "$status" -eq 0 ]
check "stage mode downloads the pinned tag" called "$t" "curl -fsSL https://github.com/PedroMosquera/tokenjar/archive/refs/tags/v0.9.0.tar.gz"
check "stage mode builds with make app" called "$t" "make app"
check "stage mode never runs make install" not_called "$t" "make install"
check "stage mode copies the built app" [ "$(cat "$stage/Tokenjar.app/Contents/marker" 2>/dev/null)" = new ]
check "stage mode copies the new install.sh" cmp -s "$stage/install.sh" "$t/src/tokenjar-0.9.0/Scripts/install.sh"
check "stage mode creates no install folder" [ ! -e "$t/home/Applications" ]
check "stage mode deletes its temporary folder" [ -z "$(ls -A "$t/tmp")" ]

# A staged app left by an earlier attempt is replaced, not merged into.
t="$(setup restage)"
stage="$t/stage"
mkdir -p "$stage/Tokenjar.app/Contents"
printf old > "$stage/Tokenjar.app/Contents/stale"
run_get "$t" TOKENJAR_STAGE_DIR="$stage"
check "restage exits 0" [ "$?" -eq 0 ]
check "restage removes the earlier app's files" [ ! -e "$stage/Tokenjar.app/Contents/stale" ]
check "restage copies the new app" [ "$(cat "$stage/Tokenjar.app/Contents/marker" 2>/dev/null)" = new ]

# A failed build stages nothing for the swap to install.
t="$(setup badbuild)"
stage="$t/stage"
run_get "$t" TOKENJAR_STAGE_DIR="$stage" FAIL_BUILD=1
check "failed build exits non-zero" [ "$?" -ne 0 ]
check "failed build stages no app" [ ! -e "$stage/Tokenjar.app" ]
check "failed build stages no install.sh" [ ! -e "$stage/install.sh" ]

# Without stage mode, get.sh still installs.
t="$(setup install)"
run_get "$t"
check "install mode exits 0" [ "$?" -eq 0 ]
check "install mode runs make install into ~/Applications" called "$t" "make install $t/home/Applications"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all get.sh checks passed"
