#!/usr/bin/env bash
#
# Builds CMDC Island and wraps it in a .app bundle.
#
#   ./make-app.sh            # release build into ./dist/CMDC Island.app
#   ./make-app.sh debug      # debug build
#
set -euo pipefail

CONFIG="${1:-release}"
NAME="CMDC Island"
BUNDLE_ID="ai.cmdc-island"
VERSION="1.0.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$NAME.app"

echo "==> Building ($CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG" --product CMDCIsland

BIN="$(swift build -c "$CONFIG" --show-bin-path)/CMDCIsland"
if [[ ! -x "$BIN" ]]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/CMDCIsland"
chmod +x "$APP/Contents/MacOS/CMDCIsland"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>CMDCIsland</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- Menu bar app: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

if [[ -f "$ROOT/assets/AppIcon.icns" ]]; then
  cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null
fi

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
  echo "note: ad-hoc signing failed; the app still runs locally"

echo
echo "Built: $APP"
echo "Run:   open \"$APP\""
