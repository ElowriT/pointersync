#!/bin/zsh
# Makes a release of PointerSync for other Macs in dist.nosync/: PointerSync.dmg and
# PointerSync.zip (the names the README links to), versioned copies of both, their
# SHA-256, and release-notes.md, the text for the release page. Nothing is uploaded.
#
# To open without a warning on other Macs, a release needs a "Developer ID Application"
# certificate (Apple Developer Program) and a notarytool keychain profile, both named in
# local.env (see local.env.example). Without them it is still made, but signed ad hoc and
# not notarized: macOS then asks people to allow it in System Settings → Privacy &
# Security → Open Anyway.
#
#   ./release.sh           build, sign, notarize when it can, package
#   ./release.sh --check   only say what it would do and what is missing
set -euo pipefail
cd "${0:A:h}"
[[ -f local.env ]] && source ./local.env

check=0
[[ ${1:-} == --check ]] && check=1
version=$(sed -nE 's/^VERSION=([0-9.]+)$/\1/p' build.sh)
dist=dist.nosync

# Only a Developer ID identity is fit to hand out. Any other (an Apple Development one
# opens nowhere else and carries its owner's name) gives way to an ad hoc signature.
identity=${POINTERSYNC_SIGN_IDENTITY:-}
profile=${POINTERSYNC_NOTARY_PROFILE:-}
developer=""
if [[ -n $identity ]]; then
    developer=$(security find-identity -v -p codesigning | grep -F -- "$identity" | grep -F "Developer ID Application" | head -1 || true)
fi
sign=-
[[ -n $developer ]] && sign=$identity
notarize=0
[[ $sign != - && -n $profile ]] && notarize=1

echo "PointerSync $version"
if [[ $sign == - ]]; then
    echo "  signing:    ad hoc (no Developer ID Application certificate set in POINTERSYNC_SIGN_IDENTITY)"
else
    echo "  signing:    ${developer#*\"}" | sed 's/"$//'
fi
if (( notarize )); then
    echo "  notarizing: yes, keychain profile '$profile'"
else
    echo "  notarizing: no$([[ $sign != - ]] && echo ' (set POINTERSYNC_NOTARY_PROFILE)')"
fi
echo "  output:     $PWD/$dist"
(( check )) && exit 0

# Sends a file to Apple's notary service and waits for its verdict.
notarize_file() {
    local result
    result=$(xcrun notarytool submit "$1" --keychain-profile "$profile" --wait --output-format json)
    if [[ $result != *'"status":"Accepted"'* ]]; then
        echo "$result"
        echo "Notarization of $1 failed. Details: xcrun notarytool log <id> --keychain-profile $profile"
        exit 1
    fi
}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
POINTERSYNC_BUILD_DIR=$stage POINTERSYNC_SIGN_IDENTITY=$sign POINTERSYNC_RELEASE=1 ./build.sh
app=$stage/PointerSync.app
codesign --verify --strict "$app"

if (( notarize )); then
    echo "Notarizing the app…"
    ditto -c -k --keepParent "$app" "$stage/upload.zip"
    notarize_file "$stage/upload.zip"
    xcrun stapler staple "$app"
fi

rm -rf "$dist"
mkdir -p "$dist" "$stage/image"
ditto -c -k --keepParent "$app" "$dist/PointerSync.zip"
# The disk image: the app and a shortcut to Applications to drag it onto.
ditto "$app" "$stage/image/PointerSync.app"
ln -s /Applications "$stage/image/Applications"
hdiutil create -quiet -volname PointerSync -srcfolder "$stage/image" -format UDZO "$dist/PointerSync.dmg"
if [[ $sign != - ]]; then
    codesign --force --timestamp --sign "$sign" "$dist/PointerSync.dmg"
fi
if (( notarize )); then
    echo "Notarizing the disk image…"
    notarize_file "$dist/PointerSync.dmg"
    xcrun stapler staple "$dist/PointerSync.dmg"
fi

cp "$dist/PointerSync.dmg" "$dist/PointerSync-$version.dmg"
cp "$dist/PointerSync.zip" "$dist/PointerSync-$version.zip"
(cd "$dist" && shasum -a 256 "PointerSync-$version.dmg" "PointerSync-$version.zip" > SHA256SUMS.txt)

# The text for the release page: how to install, in both languages, and the sums. Without
# notarization, how to get past macOS's stop on the first launch.
{
    echo "Download **PointerSync.dmg**, open it and drag PointerSync into Applications."
    echo "Скачай **PointerSync.dmg**, открой его и перетащи PointerSync в «Программы»."
    if (( ! notarize )); then
        cat <<'NOTES'

**First launch.** PointerSync isn't notarized by Apple, so the first time macOS stops it. Click **Done**, open **System Settings → Privacy & Security**, scroll down to **Security** and click **Open Anyway** next to PointerSync; confirm, and click **Open Anyway** once more. That's needed only once. Or in Terminal: `xattr -dr com.apple.quarantine /Applications/PointerSync.app`

**Первый запуск.** PointerSync не заверен Apple, поэтому в первый раз macOS его остановит. Нажми **«Готово»**, открой **Системные настройки → Конфиденциальность и безопасность**, пролистай до раздела **«Безопасность»** и нажми **«Всё равно открыть»** рядом с PointerSync; подтверди и ещё раз нажми **«Всё равно открыть»**. Это нужно один раз. Или в Терминале: `xattr -dr com.apple.quarantine /Applications/PointerSync.app`
NOTES
    fi
    echo
    echo "SHA-256:"
    echo '```'
    cat "$dist/SHA256SUMS.txt"
    echo '```'
} > "$dist/release-notes.md"

echo
echo "Made in $dist:"
ls -lh "$dist" | tail -n +2
if (( ! notarize )); then
    echo
    echo "Not notarized: on other Macs it opens only after System Settings → Privacy & Security → Open Anyway."
fi
