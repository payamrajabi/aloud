#!/bin/zsh
# Builds Read Aloud.app, signs it, installs it to /Applications and launches it.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
[[ -f Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib ]] || ./scripts/setup.sh

APP_NAME="Read Aloud"
BUNDLE_ID="co.payamrajabi.readaloud"
VERSION="1.0"
APP="build/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

echo "Compiling..."
swift build -c release --arch arm64 2>&1 | grep -E "error|warning: |Compiling|Build complete" || true
BIN=".build/arm64-apple-macosx/release/ReadAloud"
[[ -x "$BIN" ]] || { echo "Build failed"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ReadAloud"
cp -L Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib Vendor/sherpa-onnx/lib/libonnxruntime.dylib "$APP/Contents/Frameworks/"
# Remove the developer-only library path so the app only uses its bundled copies.
install_name_tool -delete_rpath "$ROOT/Vendor/sherpa-onnx/lib" "$APP/Contents/MacOS/ReadAloud" 2>/dev/null || true

if [[ ! -f build/AppIcon.icns ]]; then
  ICONSET=build/AppIcon.iconset
  mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>ReadAloud</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign with the Apple Development certificate if present so macOS remembers the
# Accessibility permission across rebuilds; otherwise fall back to ad-hoc signing.
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
IDENTITY=${IDENTITY:--}
echo "Signing with: $IDENTITY"
codesign --force --timestamp=none --options runtime -s "$IDENTITY" "$APP/Contents/Frameworks/"*.dylib
codesign --force --timestamp=none --options runtime -s "$IDENTITY" "$APP"

echo "Installing to $DEST..."
pkill -x ReadAloud 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Done. Look for the waveform icon in the menu bar."
