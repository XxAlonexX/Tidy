#!/bin/bash
# Builds "Tidy.app" (universal) and "Tidy-<version>.dmg" in mac/build/.
#
#   ./build.sh                                   # ad-hoc signed (fine for testing; Gatekeeper warns on other Macs)
#   SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=jev ./build.sh
#                                                # signed + notarized + stapled, ready to publish
#
# NOTARY_PROFILE is a keychain profile created once with:
#   xcrun notarytool store-credentials jev --apple-id you@example.com --team-id TEAMID
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Tidy"
EXEC="Tidy"
BUNDLE_ID="${BUNDLE_ID:-com.tidyapp.mac}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MIN_MACOS="13.0"
SIGN_ID="${SIGN_ID:--}"

BUILD="build"
APP="$BUILD/$APP_NAME.app"
DMG="$BUILD/Tidy-$VERSION.dmg"

rm -rf "$APP" "$DMG" "$BUILD/dmg" "$BUILD/obj"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/obj"

echo "▸ Compiling (arm64 + x86_64)"
for arch in arm64 x86_64; do
  swiftc -swift-version 6 -O -target "$arch-apple-macos$MIN_MACOS" Sources/*.swift -o "$BUILD/obj/$EXEC-$arch" 2> "$BUILD/obj/swiftc-$arch.log" \
    || { cat "$BUILD/obj/swiftc-$arch.log"; exit 1; }
done
lipo -create "$BUILD/obj/$EXEC-arm64" "$BUILD/obj/$EXEC-x86_64" -output "$APP/Contents/MacOS/$EXEC"

echo "▸ Resources + icon"
cp Resources/index.html "$APP/Contents/Resources/"
ICONSET="$BUILD/obj/AppIcon.iconset"
mkdir -p "$ICONSET"
swift scripts/make_icon.swift "$BUILD/obj/icon_1024.png" > /dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/obj/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" > /dev/null
  d=$((s * 2))
  sips -z $d $d "$BUILD/obj/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Free to use. Support it once for ₹69 if you love it.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Tidy sorts the files on your Desktop into folders.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Tidy sorts the files in folders you choose.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Tidy sorts the files in folders you choose.</string>
</dict>
</plist>
PLIST

echo "▸ Signing ($SIGN_ID)"
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "▸ Building DMG"
mkdir -p "$BUILD/dmg"
cp -R "$APP" "$BUILD/dmg/"
ln -s /Applications "$BUILD/dmg/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$BUILD/dmg" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" > /dev/null
rm -rf "$BUILD/dmg"
if [ "$SIGN_ID" != "-" ]; then codesign --force --sign "$SIGN_ID" --timestamp "$DMG"; fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▸ Notarizing (a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "✓ $APP"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
