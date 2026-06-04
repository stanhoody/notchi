#!/usr/bin/env bash
# build-app.sh — wraps the SPM-built `notchi` executable into Notchi.app.
#
# Usage:
#   ./scripts/build-app.sh                   → builds release, installs to ~/Applications/Notchi.app
#   ./scripts/build-app.sh --dev             → builds debug, installs to ./dist/Notchi.app
#
# This is a personal-hack installer. Unsigned, not notarized — Stan will see
# "Notchi is from an unidentified developer" once and have to right-click → Open.

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="release"
DEST="$HOME/Applications/Notchi.app"

if [[ "${1:-}" == "--dev" ]]; then
  CONFIG="debug"
  DEST="$(pwd)/dist/Notchi.app"
fi

echo "[build-app] swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH=".build/$CONFIG/notchi"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: $BIN_PATH not found after build" >&2
  exit 1
fi

echo "[build-app] assembling app bundle at $DEST"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS"
mkdir -p "$DEST/Contents/Resources"
cp "$BIN_PATH" "$DEST/Contents/MacOS/notchi"
chmod +x "$DEST/Contents/MacOS/notchi"

cat > "$DEST/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>notchi</string>
    <key>CFBundleIdentifier</key>
    <string>com.stanhoody.notchi</string>
    <key>CFBundleName</key>
    <string>Notchi</string>
    <key>CFBundleDisplayName</key>
    <string>Notchi</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "[build-app] done → $DEST"
echo
echo "Next:"
echo "  open '$DEST'                # launch"
echo "  # First launch may need right-click → Open to bypass Gatekeeper."
