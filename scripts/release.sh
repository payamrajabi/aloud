#!/bin/zsh
# Publishes a downloadable build: ./scripts/release.sh 1.0.0
# Builds the app with the voice model inside, wraps it in a disk image,
# notarizes it with Apple when possible, and uploads it as a GitHub release.
# The website's download button always points at the newest release.
#
# Notarization runs automatically once both of these exist on this Mac:
#   - a "Developer ID Application" certificate (Xcode → Settings → Accounts → Manage Certificates)
#   - saved notary credentials:  xcrun notarytool store-credentials readaloud --apple-id <email> --team-id <team>
set -euo pipefail

VERSION="${1:?Usage: scripts/release.sh <version>, e.g. 1.0.0}"
ROOT="${0:A:h:h}"
cd "$ROOT"
APP="build/Read Aloud.app"
DMG="build/ReadAloud.dmg"

VERSION="$VERSION" BUNDLE_MODEL=1 INSTALL=0 ./scripts/build-app.sh
IDENTITY=$(cat build/signing-identity)

echo "Creating disk image..."
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Read Aloud" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
[[ "$IDENTITY" != "-" ]] && codesign --force --timestamp=none -s "$IDENTITY" "$DMG"

NOTARIZED=0
if [[ "$IDENTITY" == Developer\ ID\ Application* ]] && xcrun notarytool history --keychain-profile readaloud >/dev/null 2>&1; then
  echo "Notarizing with Apple (usually a few minutes)..."
  codesign --force --timestamp -s "$IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile readaloud --wait
  xcrun stapler staple "$DMG"
  NOTARIZED=1
else
  echo "Skipping notarization (no Developer ID certificate or notary credentials yet)."
fi

SIZE=$(du -m "$DMG" | cut -f1)
NOTES="Download **ReadAloud.dmg**, open it, and drag Read Aloud into Applications. Requires an Apple Silicon Mac with macOS 14 or later. (${SIZE} MB)"
if [[ $NOTARIZED == 0 ]]; then
  NOTES="$NOTES

This build isn't notarized by Apple yet. The first time you open it, macOS will say it can't verify the app: open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**."
fi

TAG="v$VERSION"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" --clobber
  gh release edit "$TAG" --notes "$NOTES"
else
  gh release create "$TAG" "$DMG" --title "Read Aloud $VERSION" --notes "$NOTES" --latest
fi
echo "Released $TAG ($SIZE MB, notarized: $NOTARIZED)"
