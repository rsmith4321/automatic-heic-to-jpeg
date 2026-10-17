#!/bin/zsh
# Builds Automatic HEIC to JPEG.app (universal: Apple silicon and Intel).
#   ./build.sh            build, install to /Applications and start it
#   ./build.sh --release  build, notarize, and make a DMG and a zip in build/ (no install)
#
# Signing: uses $SIGN_IDENTITY, else the first "Developer ID Application"
# identity in your keychain, else an ad hoc signature (fine for your own Mac).
# Notarizing (--release only) needs a notarytool keychain profile named by
# $NOTARY_PROFILE (create one with `xcrun notarytool store-credentials`).
set -euo pipefail
cd "${0:A:h}"

NAME="Automatic HEIC to JPEG"
APP="build/$NAME.app"
RELEASE=0
[[ "${1:-}" == "--release" ]] && RELEASE=1
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
if (( RELEASE )) && [[ -z "$IDENTITY" || -z "${NOTARY_PROFILE:-}" ]]; then
  echo "A release needs a Developer ID Application identity and NOTARY_PROFILE set." >&2
  exit 1
fi

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos14.0" -o "build/$arch" Sources/*.swift
done
lipo -create build/arm64 build/x86_64 -output "$APP/Contents/MacOS/$NAME"
rm build/arm64 build/x86_64
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

if [[ -n "$IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

if (( RELEASE )); then
  BASE="Automatic-HEIC-to-JPEG-$VERSION"
  (cd build && ditto -c -k --keepParent "$NAME.app" notarize.zip)
  notarize build/notarize.zip
  rm build/notarize.zip
  xcrun stapler staple "$APP"
  (cd build && ditto -c -k --keepParent "$NAME.app" "$BASE.zip")

  STAGE=build/dmg
  mkdir -p "$STAGE" && cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$NAME" -srcfolder "$STAGE" -format UDZO -ov "build/$BASE.dmg" >/dev/null
  rm -rf "$STAGE"
  codesign --sign "$IDENTITY" --timestamp "build/$BASE.dmg"
  notarize "build/$BASE.dmg"
  xcrun stapler staple "build/$BASE.dmg"
  spctl --assess --type open --context context:primary-signature -v "build/$BASE.dmg"
  spctl --assess --type execute -v "$APP"
  echo "Built build/$BASE.dmg and build/$BASE.zip"
  exit 0
fi

DEST="/Applications/$NAME.app"
pkill -x "$NAME" 2>/dev/null && sleep 1 || true
rm -rf "$DEST" && cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed $DEST"
