#!/usr/bin/env bash
# Assembles build/Tokenjar.app from the release binary and Resources/. Run via `make app`.
set -euo pipefail
cd "$(dirname "$0")/.."

SCRATCH="${SCRATCH:-.build}"
APP=build/Tokenjar.app
BIN_DIR=$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)
VERSION=$(cat VERSION 2>/dev/null || echo 0.1.0)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Tokenjar" "$APP/Contents/MacOS/Tokenjar"
cp -R Resources/Logos "$APP/Contents/Resources/Logos"
[ -f Resources/pricing.json ] && cp Resources/pricing.json "$APP/Contents/Resources/pricing.json"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tokenjar</string>
    <key>CFBundleDisplayName</key><string>Tokenjar</string>
    <key>CFBundleIdentifier</key><string>com.pedromosquera.tokenjar</string>
    <key>CFBundleExecutable</key><string>Tokenjar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Pedro Mosquera. MIT License.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# The binary must not depend on anything under the CLT install (another Mac may have a different one, or none).
if otool -L "$APP/Contents/MacOS/Tokenjar" | grep -q '@rpath/'; then
  echo "error: binary links an @rpath library; bundle it or drop the dependency" >&2
  otool -L "$APP/Contents/MacOS/Tokenjar" >&2
  exit 1
fi

xattr -cr "$APP"
codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION, build $BUILD)"
