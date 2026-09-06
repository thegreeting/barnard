#!/usr/bin/env bash
# Use of this source code is governed by a BSD-style license.
#
# Build the lab runner with SwiftPM and assemble it into LabRunner.app.
#
# The .app wrapper is not cosmetic. macOS keys the Bluetooth grant to a bundle
# identity and a code signature, so a bare executable would be prompted for (or
# refused) differently on every run. Info.plist is written here rather than
# checked in because it has to agree with the built binary's name.
#
# Environment:
#   CONFIGURATION       debug or release (default: release)
#   CODESIGN_IDENTITY   signing identity; ad-hoc "-" when unset. A stable
#                       identity is what makes the Bluetooth grant survive a
#                       rebuild, so the lab host should set it.
#   BUILD_DIR           SwiftPM scratch path (default: ./.build)
#   APP_DIR             where LabRunner.app is assembled (default: ./build)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_NAME="BarnardLabRunner"
BUNDLE_ID="org.levarac.barnard.LabRunner"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="${BUILD_DIR:-$EXAMPLE_DIR/.build}"
APP_DIR="${APP_DIR:-$EXAMPLE_DIR/build}"
APP="$APP_DIR/LabRunner.app"

cd "$EXAMPLE_DIR"

swift build -c "$CONFIGURATION" --scratch-path "$BUILD_DIR" >&2
BINARY="$(swift build -c "$CONFIGURATION" --scratch-path "$BUILD_DIR" --show-bin-path)/$BINARY_NAME"
if [ ! -x "$BINARY" ]; then
  echo "bundle.sh: built binary not found at $BINARY" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/$BINARY_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>
  <string>$BINARY_NAME</string>
  <key>CFBundleName</key>
  <string>LabRunner</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <!-- Headless: no Dock icon and no menu bar. The device-lab orchestrator
       backgrounds this process and reads its stdout. -->
  <key>LSUIElement</key>
  <true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Barnard uses Bluetooth to scan for and advertise to nearby devices running the Barnard protocol.</string>
</dict>
</plist>
PLIST

# Ad-hoc by default so this builds on any Mac and in CI with no keychain. An
# ad-hoc signature changes on every rebuild, which drops the Bluetooth grant;
# CODESIGN_IDENTITY is how the lab host avoids that.
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" >&2

echo "$APP/Contents/MacOS/$BINARY_NAME"
