#!/bin/zsh
# Builds PointerSync Lab.app: the measuring and smoothing workbench behind PointerSync.
# Sign it with a stable identity (POINTERSYNC_SIGN_IDENTITY, or local.env in the folder
# above) so macOS keeps its Input Monitoring and Accessibility permissions across
# rebuilds; without one it is signed ad hoc and asks again after every build.
# The app goes outside ~/Documents: iCloud tags bundles there with Finder info,
# which codesign refuses.
set -euo pipefail
cd "${0:A:h}"
[[ -f ../local.env ]] && source ../local.env

APP="${POINTERSYNC_BUILD_DIR:-$HOME/Library/Developer/PointerSync}/PointerSync Lab.app"
IDENTITY=${POINTERSYNC_SIGN_IDENTITY:--}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
    -o "$APP/Contents/MacOS/PointerSyncLab" Sources/*.swift ../Shared/*.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.elowrit.pointersync.lab</string>
    <key>CFBundleName</key><string>PointerSync Lab</string>
    <key>CFBundleDisplayName</key><string>PointerSync Lab</string>
    <key>CFBundleExecutable</key><string>PointerSyncLab</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

xattr -cr "$APP"
codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
echo "Built $APP"
