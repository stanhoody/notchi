#!/usr/bin/env bash
# Build Notchi in release mode and assemble ~/Applications/Notchi.app.
# Unsigned, LSUIElement (agent) app. Re-run to update.
set -euo pipefail

cd "$(dirname "$0")/.."          # → src/
APP="$HOME/Applications/Notchi.app"
VERSION="0.1.0"

echo "Building release…"
swift build -c release

BIN=".build/release/notchi"
[[ -x "$BIN" ]] || { echo "build produced no binary at $BIN"; exit 1; }

echo "Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/notchi"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Notchi</string>
  <key>CFBundleDisplayName</key><string>Notchi</string>
  <key>CFBundleIdentifier</key><string>com.stanhoody.notchi</string>
  <key>CFBundleExecutable</key><string>notchi</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS is happy launching it locally.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"

echo "Done. Launch with:  open \"$APP\""
echo "Quit any dev instance first:  pkill -f .build/.*/notchi"
