#!/bin/zsh
# Builds Aloud.app, signs it, installs it to /Applications and launches it.
# Options (environment variables):
#   VERSION=1.2.0    version number shown in Finder
#   BUNDLE_MODEL=1   put the voice model inside the app (otherwise the app downloads it on first launch)
#   INSTALL=0        build only; don't install or launch
#   BUILD_NUMBER=n   override CFBundleVersion (defaults to the commit count; Sparkle compares it)
#   FEED_URL=url     where the app looks for updates (Sparkle appcast). Every copy keeps
#                    checking this address forever, so it must stay reachable.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
[[ -f Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib && -d Vendor/llama.xcframework ]] || ./scripts/setup.sh

APP_NAME="Aloud"
FEED_URL="${FEED_URL:-https://aloudformac.com/appcast.xml}"
BUNDLE_ID="${BUNDLE_ID:-co.payamrajabi.readaloud}"
VERSION="${VERSION:-1.0.0}"
APP="build/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

echo "Compiling..."
swift build -c release --arch arm64 2>&1 | grep -E "error|warning: |Compiling|Build complete" || true
BIN=".build/arm64-apple-macosx/release/ReadAloud"
[[ -x "$BIN" ]] || { echo "Build failed"; exit 1; }
SPARKLE=".build/arm64-apple-macosx/release/Sparkle.framework"
[[ -d "$SPARKLE" ]] || { echo "Sparkle.framework missing from the build products"; exit 1; }
LLAMA=".build/arm64-apple-macosx/release/llama.framework"
[[ -d "$LLAMA" ]] || { echo "llama.framework missing from the build products"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ReadAloud"
cp -L Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib Vendor/sherpa-onnx/lib/libonnxruntime.dylib "$APP/Contents/Frameworks/"
# Sparkle (auto-updates). ditto keeps the framework's internal symlinks.
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
# llama.cpp (the language model that tidies dictation). Only the Apple silicon slice.
ditto --arch arm64 "$LLAMA" "$APP/Contents/Frameworks/llama.framework"
# Remove the developer-only library path so the app only uses its bundled copies.
install_name_tool -delete_rpath "$ROOT/Vendor/sherpa-onnx/lib" "$APP/Contents/MacOS/ReadAloud" 2>/dev/null || true

if [[ ! build/AppIcon.icns -nt scripts/make-icon.swift ]]; then
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
cp LICENSE THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/"

if [[ "${BUNDLE_MODEL:-0}" == 1 ]]; then
  MODEL="$HOME/Library/Application Support/ReadAloud/models/kokoro-multi-lang-v1_0"
  [[ -f "$MODEL/model.onnx" ]] || ./scripts/setup.sh
  echo "Bundling voice model..."
  # dict/ and the .fst files are only used for Chinese text normalization, which we don't configure.
  rsync -a --exclude dict --exclude '*.fst' "$MODEL" "$APP/Contents/Resources/"
fi

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
  <key>CFBundleVersion</key><string>${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>Aloud license</string>
    <key>CFBundleURLSchemes</key><array><string>aloud</string></array>
  </dict></array>
  <key>NSMicrophoneUsageDescription</key><string>Aloud listens only while you dictate, and transcribes on your Mac.</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>5vUlD146c8QQ89zPzk3BgpG7ivGEHbrUiH1SBSRSL6M=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

# Prefer a Developer ID certificate (required for Apple notarization), then the
# Apple Development certificate (so macOS remembers the Accessibility permission
# across rebuilds), then ad-hoc signing.
IDENTITIES=$(security find-identity -v -p codesigning)
IDENTITY=$(echo "$IDENTITIES" | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)
TIMESTAMP="--timestamp"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(echo "$IDENTITIES" | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
  TIMESTAMP="--timestamp=none"
fi
IDENTITY=${IDENTITY:--}
echo "Signing with: $IDENTITY"
echo "$IDENTITY" > build/signing-identity
codesign --force $TIMESTAMP --options runtime -s "$IDENTITY" "$APP/Contents/Frameworks/"*.dylib
codesign --force $TIMESTAMP --options runtime -s "$IDENTITY" "$APP/Contents/Frameworks/llama.framework"
# Sparkle's helpers are signed inside-out with our identity (Sparkle's guide for builds outside Xcode).
SPK="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force $TIMESTAMP --options runtime -s "$IDENTITY" "$SPK/Versions/B/XPCServices/Installer.xpc"
codesign --force $TIMESTAMP --options runtime --preserve-metadata=entitlements -s "$IDENTITY" "$SPK/Versions/B/XPCServices/Downloader.xpc"
codesign --force $TIMESTAMP --options runtime -s "$IDENTITY" "$SPK/Versions/B/Autoupdate"
codesign --force $TIMESTAMP --options runtime -s "$IDENTITY" "$SPK/Versions/B/Updater.app"
codesign --force $TIMESTAMP --options runtime -s "$IDENTITY" "$SPK"
cat > build/entitlements.plist <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
ENT
codesign --force $TIMESTAMP --options runtime --entitlements build/entitlements.plist -s "$IDENTITY" "$APP"

if [[ "${INSTALL:-1}" == 0 ]]; then
  echo "Built $APP"
  exit 0
fi

echo "Installing to $DEST..."
pkill -x ReadAloud 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST" "/Applications/Read Aloud.app"   # the app was called Read Aloud before 1.2
cp -R "$APP" "$DEST"
open "$DEST"
echo "Done. Look for the waveform icon in the menu bar."
