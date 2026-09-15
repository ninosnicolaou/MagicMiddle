#!/bin/zsh
set -euo pipefail

APP_NAME="Magic Middle"
BUNDLE_ID="com.local.MagicMiddle"
APP_VERSION="${APP_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
BIN="$APP/Contents/MacOS/MagicMiddle"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>MagicMiddle</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

SDK="$(xcrun --sdk macosx --show-sdk-path)"

# Use a prebuilt ICNS file so the app can be built with Command Line Tools only.
if [[ -f "$ROOT/MagicMiddle/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/MagicMiddle/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

clang -fobjc-arc -Wall -Wextra -O2 -mmacosx-version-min=13.0 \
  -arch arm64 \
  -isysroot "$SDK" -framework Cocoa -framework CoreGraphics -framework CoreFoundation \
  "$ROOT/MagicMiddle/main.m" -o "$BIN"

# Ad-hoc sign so macOS treats it as a normal app bundle.
codesign --force --deep --sign - "$APP" >/dev/null

echo
echo "Built: $APP"
echo
echo "To install:"
echo "  cp -R \"$APP\" /Applications/"
echo
echo "Then launch it from Applications."
