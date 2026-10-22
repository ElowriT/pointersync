#!/bin/zsh
# Builds PointerSync.app, the one-time setup tool: measure the mouse, pick the screen's
# refresh rate, done. The app goes outside ~/Documents: iCloud tags bundles there with
# Finder info, which codesign refuses. The measuring workbench is Lab/build.sh; a release
# for other Macs is release.sh.
#
# Signing is ad hoc unless POINTERSYNC_SIGN_IDENTITY names a certificate (local.env can
# set it, see local.env.example). POINTERSYNC_RELEASE=1 adds what notarization needs: the
# hardened runtime and a secure timestamp.
set -euo pipefail
cd "${0:A:h}"
[[ -f local.env ]] && source ./local.env

VERSION=1.5
BUILD=7
APP=${POINTERSYNC_BUILD_DIR:-$HOME/Library/Developer/PointerSync}/PointerSync.app
IDENTITY=${POINTERSYNC_SIGN_IDENTITY:--}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
    -o "$APP/Contents/MacOS/PointerSync" App/*.swift Shared/*.swift

# The icon is Icon Composer's layered document; actool turns it into what macOS draws with
# Liquid Glass (Assets.car), plus a flat .icns for anything older.
ICON=$(mktemp -d)
xcrun actool --compile "$ICON" --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon \
    --output-partial-info-plist "$ICON/partial.plist" Assets/AppIcon.icon > /dev/null
cp "$ICON/Assets.car" "$ICON/AppIcon.icns" "$APP/Contents/Resources/"
rm -rf "$ICON"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.elowrit.pointersync</string>
    <key>CFBundleName</key><string>PointerSync</string>
    <key>CFBundleDisplayName</key><string>PointerSync</string>
    <key>CFBundleExecutable</key><string>PointerSync</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
    <key>NSHumanReadableCopyright</key><string>© 2026 ElowriT</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

xattr -cr "$APP"
if [[ ${POINTERSYNC_RELEASE:-0} == 1 && $IDENTITY != - ]]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
elif [[ ${POINTERSYNC_RELEASE:-0} == 1 ]]; then
    codesign --force --options runtime --sign - "$APP"   # ad hoc signatures carry no timestamp
else
    codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
fi
echo "Built $APP"
