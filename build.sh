#!/bin/bash
# Build ChromeSTT.app with a stable signing identity.
#
# Ad-hoc signing (`-`) ties the TCC grant to the binary's cdhash, so every
# rebuild silently revokes Accessibility. Signing with a real certificate ties
# it to team + bundle ID instead, which survives rebuilds.

set -euo pipefail

IDENTITY="${CHROMESTT_IDENTITY:-Apple Development: rachen9789@gmail.com (BT9S85952K)}"
APP="${1:-$HOME/Desktop/ChromeSTT.app}"
REPO="$(cd "$(dirname "$0")" && pwd)"

echo "==> Building release binary"
cd "$REPO"
swift build -c release

echo "==> Assembling $APP"
pkill -f ChromeSTT 2>/dev/null || true
sleep 1
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ChromeSTT "$APP/Contents/MacOS/ChromeSTT"
chmod +x "$APP/Contents/MacOS/ChromeSTT"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ChromeSTT</string>
    <key>CFBundleIdentifier</key><string>com.nub.chromestt</string>
    <key>CFBundleName</key><string>ChromeSTT</string>
    <key>CFBundleDisplayName</key><string>ChromeSTT</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
PLIST
echo "</plist>" >> "$APP/Contents/Info.plist"

echo "==> Signing with: $IDENTITY"
xattr -cr "$APP"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|TeamIdentifier|Authority' | head -3

echo "==> Done. Launch with: open \"$APP\""
