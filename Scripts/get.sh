#!/usr/bin/env bash
# Installs Tokenjar without Homebrew or a clone:
#   curl -fsSL https://raw.githubusercontent.com/PedroMosquera/tokenjar/main/Scripts/get.sh | bash
# Downloads the latest release's source archive (TOKENJAR_VERSION=0.3.0 picks another), builds it with `make install`
# in a temporary folder, then deletes that folder. An argument installs into that folder instead of ~/Applications.
set -euo pipefail

# Everything runs from main, so a download cut short by the network runs nothing.
main() {
  local repo=https://github.com/PedroMosquera/tokenjar
  case "${1:-}" in
    -*)
      echo "error: this installer takes no options, only the folder to install into (~/Applications by default)." >&2
      exit 64
      ;;
  esac

  if [ "$(uname -s)" != Darwin ]; then
    echo "error: Tokenjar runs only on macOS." >&2
    exit 1
  fi
  # Checked before swift runs: without developer tools, /usr/bin/swift opens the install dialog instead of answering.
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "error: the Command Line Tools are not installed. Run xcode-select --install, then run this installer again." >&2
    exit 1
  fi
  local swift_version
  swift_version="$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)"
  if [ -z "$swift_version" ] || [ "${swift_version%%.*}" -lt 6 ] ||
    { [ "${swift_version%%.*}" -eq 6 ] && [ "${swift_version#*.}" -lt 2 ]; }; then
    echo "error: Tokenjar needs Swift 6.2 or later, and swift --version shows ${swift_version:-none}." >&2
    echo "Update the Command Line Tools from Software Update in System Settings, then run this installer again." >&2
    exit 1
  fi

  local tag
  if [ -n "${TOKENJAR_VERSION:-}" ]; then
    tag="v${TOKENJAR_VERSION#v}"
  else
    # GitHub redirects releases/latest to releases/tag/<tag>, which needs no API call and no rate limit.
    tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$repo/releases/latest" || true)"
    tag="${tag##*/}"
    case "$tag" in
      v[0-9]*) ;;
      *)
        echo "error: could not find the latest Tokenjar release on GitHub. Nothing was changed." >&2
        exit 1
        ;;
    esac
  fi

  local work
  work="$(mktemp -d "${TMPDIR:-/tmp}/tokenjar-install.XXXXXX")"
  # shellcheck disable=SC2064 # expanded now, since $work is local and gone once main returns
  trap "rm -rf '$work'" EXIT

  echo "Downloading Tokenjar $tag"
  if ! curl -fsSL "$repo/archive/refs/tags/$tag.tar.gz" | tar -xzf - -C "$work" --strip-components 1; then
    echo "error: could not download Tokenjar $tag from $repo. Nothing was changed." >&2
    exit 1
  fi

  # Absolute before the build, because install.sh runs from the source folder and would resolve a relative path there.
  local dest="${1:-$HOME/Applications}"
  mkdir -p "$dest"
  dest="$(CDPATH='' cd -- "$dest" && pwd)"

  echo "Building Tokenjar $tag. This takes a minute or a few."
  make -C "$work" install INSTALL_DIR="$dest"
}

main "$@"
