#!/bin/zsh
# Publishes a downloadable build: ./scripts/release.sh 1.0.0
# Builds the app (the voice model downloads on first launch, so it isn't inside),
# wraps it in a disk image, notarizes it with Apple when possible, uploads it as a
# GitHub release, and adds it to docs/appcast.xml, the feed Sparkle checks for updates.
# The website's download button always points at the newest release.
#
# Optional: RELEASE_NOTES="One or two sentences" shows in the update window.
#           SPARKLE_ED_KEY_FILE=path signs the update with an exported key instead of the Keychain.
#           DOWNLOAD_BASE_URL=url  where update downloads live; the appcast points at
#                                  <url>/v<version>/Aloud.dmg (default: aloudformac.com/releases,
#                                  which redirects to RELEASES_REPO's GitHub releases).
#           RELEASES_REPO=owner/name  public GitHub repo the DMG is published to.
#           APPCAST=path           the feed file to update (default docs/appcast.xml, served at aloudformac.com by Vercel).
#           FEED_URL=url           passed through to build-app.sh (see there).
#
# Notarization runs automatically once both of these exist on this Mac:
#   - a "Developer ID Application" certificate (Xcode → Settings → Accounts → Manage Certificates)
#   - saved notary credentials:  xcrun notarytool store-credentials readaloud --apple-id <email> --team-id <team>
# Update signing needs the Sparkle private key in the login Keychain
# ("Private key for signing Sparkle updates", created by Sparkle's generate_keys).
set -euo pipefail

VERSION="${1:?Usage: scripts/release.sh <version>, e.g. 1.0.0}"
ROOT="${0:A:h:h}"
cd "$ROOT"
APP="build/Aloud.app"
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-https://aloudformac.com/releases}"   # redirects to RELEASES_REPO (docs/vercel.json)
RELEASES_REPO="${RELEASES_REPO:-payamrajabi/aloud-releases}"                 # public repo that only holds the DMGs
APPCAST="${APPCAST:-docs/appcast.xml}"
DMG="build/Aloud.dmg"

# The release notes name this commit, so it must already be on GitHub.
COMMIT=$(git rev-parse HEAD)
git fetch -q origin
if [[ -z "$(git branch -r --contains "$COMMIT")" ]]; then
  echo "Push this commit ($COMMIT) to GitHub first, then run the release again."
  exit 1
fi

[[ -d .build/artifacts ]] || swift package resolve
SIGN_UPDATE=$(find .build/artifacts -type f -path '*/Sparkle/bin/sign_update' | head -1)
[[ -x "$SIGN_UPDATE" ]] || { echo "Couldn't find Sparkle's sign_update tool (run: swift package resolve)"; exit 1; }

VERSION="$VERSION" INSTALL=0 ./scripts/build-app.sh
IDENTITY=$(cat build/signing-identity)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")

echo "Creating disk image..."
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Aloud" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
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

# Sign the finished (stapled) disk image for Sparkle. Prints: sparkle:edSignature="..." sparkle:length="..."
echo "Signing the update for Sparkle..."
# The key comes from the Keychain (macOS asks once; choose Always Allow), or from
# SPARKLE_ED_KEY_FILE for unattended runs.
KEY_ARGS=()
[[ -n "${SPARKLE_ED_KEY_FILE:-}" ]] && KEY_ARGS=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
SPARKLE_SIG=$("$SIGN_UPDATE" "${KEY_ARGS[@]}" "$DMG")
ED_SIGNATURE=$(echo "$SPARKLE_SIG" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')
LENGTH=$(echo "$SPARKLE_SIG" | sed -E 's/.*length="([0-9]+)".*/\1/')
[[ -n "$ED_SIGNATURE" && "$LENGTH" == <-> ]] || { echo "sign_update failed: $SPARKLE_SIG"; exit 1; }

SIZE=$(du -m "$DMG" | cut -f1)
NOTES="Download **Aloud.dmg**, open it, and drag Aloud into Applications. Requires an Apple Silicon Mac with macOS 14 or later. (${SIZE} MB; the voice, about 355 MB, downloads the first time you open it.) If you already have Aloud 1.4 or later, it updates itself."
if [[ $NOTARIZED == 0 ]]; then
  NOTES="$NOTES

This build isn't notarized by Apple yet. The first time you open it, macOS will say it can't verify the app: open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**."
fi

TAG="v$VERSION"
if gh release view "$TAG" -R "$RELEASES_REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" -R "$RELEASES_REPO" --clobber
  gh release edit "$TAG" -R "$RELEASES_REPO" --notes "$NOTES"
else
  gh release create "$TAG" "$DMG" -R "$RELEASES_REPO" --title "Aloud $VERSION" --notes "$NOTES (Built from $COMMIT.)" --latest
fi

python3 scripts/update-appcast.py "$APPCAST" "$VERSION" "$BUILD" "$ED_SIGNATURE" "$LENGTH" \
  "$DOWNLOAD_BASE_URL/v$VERSION/Aloud.dmg" "${RELEASE_NOTES:-}"

echo "Released $TAG ($SIZE MB, build $BUILD, notarized: $NOTARIZED)"
echo
echo "Next: commit $APPCAST and push it to main. Installed copies only see the update once it's served at the feed URL."
