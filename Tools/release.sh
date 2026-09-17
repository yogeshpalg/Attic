#!/bin/bash
#
# Builds, signs, notarizes and packages Attic for direct distribution.
#
#   Tools/release.sh            build, notarize, staple, package
#   Tools/release.sh --check    report what is missing and stop
#   Tools/release.sh --no-notarize   build and package without notarizing
#
# Every step verifies its own result rather than assuming the previous one
# worked: an unsigned or un-stapled build that reaches somebody else shows
# "Apple could not verify this app", which is the worst possible first
# impression for an app that asks to look through a disk.

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="Attic.xcodeproj"
SCHEME="Attic"
APP_NAME="Attic"
KEYCHAIN_PROFILE="attic-notary"   # see RELEASING.md for the one-time setup
BUILD_DIR="build/release"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/$APP_NAME.app"

NOTARIZE=1
CHECK_ONLY=0
for argument in "$@"; do
    case "$argument" in
        --check) CHECK_ONLY=1 ;;
        --no-notarize) NOTARIZE=0 ;;
        *) echo "unknown option: $argument" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preflight

step "Checking what is needed"

VERSION=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ MARKETING_VERSION/ {print $2; exit}')
BUILD_NUMBER=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ CURRENT_PROJECT_VERSION/ {print $2; exit}')
echo "version:        $VERSION ($BUILD_NUMBER)"

# A Developer ID Application certificate is the one that matters here. An
# Apple Development or Apple Distribution certificate will sign a build that
# Gatekeeper then refuses, which is a confusing way to find out.
IDENTITY=$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
if [ -z "$IDENTITY" ]; then
    echo "signing:        MISSING — no Developer ID Application certificate"
    MISSING=1
else
    echo "signing:        $IDENTITY"
fi

if [ "$NOTARIZE" = 1 ]; then
    if xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
        echo "notary:         keychain profile '$KEYCHAIN_PROFILE' works"
    else
        echo "notary:         MISSING — no working '$KEYCHAIN_PROFILE' profile"
        MISSING=1
    fi
fi

if [ "${MISSING:-0}" = 1 ]; then
    echo ""
    echo "See RELEASING.md for how to create these. Nothing has been built."
    exit 1
fi

[ "$CHECK_ONLY" = 1 ] && { echo ""; echo "Everything needed is present."; exit 0; }

# ---------------------------------------------------------------- tests

step "Running the tests"
# Releasing on a red suite is how a safety app ships a bug that deletes
# something. The suite takes seconds; there is no excuse to skip it.
xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
    -destination 'platform=macOS,arch=arm64' -quiet

# ---------------------------------------------------------------- archive

step "Archiving"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release -archivePath "$ARCHIVE" \
    -destination 'generic/platform=macOS' -quiet

cat > "$BUILD_DIR/export-options.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>5KP386UDP6</string>
</dict>
</plist>
PLIST

step "Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$BUILD_DIR/export-options.plist" \
    -exportPath "$EXPORT_DIR" -quiet

[ -d "$APP" ] || fail "the export produced no app"

# ---------------------------------------------------------------- verify

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"

# Hardened runtime is a notarization requirement, and it is set on Release
# only — so this is also the check that the archive really used Release.
if ! codesign -d --verbose=4 "$APP" 2>&1 | grep -q "flags=0x10000(runtime)"; then
    fail "the app is not built with the hardened runtime"
fi
echo "hardened runtime: present"

# ---------------------------------------------------------------- notarize

DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

step "Building the disk image"
# A read-only compressed image containing the app and a link to
# /Applications, which is what people expect to drag into.
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" \
    -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGING"

if [ "$NOTARIZE" = 1 ]; then
    step "Notarizing (this waits for Apple)"
    # The DMG is submitted rather than the app, so the thing people actually
    # download is the thing that carries the ticket.
    xcrun notarytool submit "$DMG" \
        --keychain-profile "$KEYCHAIN_PROFILE" --wait

    step "Stapling"
    xcrun stapler staple "$DMG"

    step "Checking it the way a new Mac will"
    # `spctl -a` on the mounted app is the closest thing to a first-launch
    # test without a second machine. It is not a substitute for one.
    xcrun stapler validate "$DMG"
    MOUNT=$(hdiutil attach "$DMG" -nobrowse -readonly | awk -F'\t' '/Apple_HFS|Apple_APFS/ {print $NF}' | tail -1)
    if [ -n "$MOUNT" ]; then
        spctl --assess --type execute --verbose=2 "$MOUNT/$APP_NAME.app" || true
        hdiutil detach "$MOUNT" -quiet
    fi
fi

step "Done"
echo "$DMG"
ls -lh "$DMG" | awk '{print "size:", $5}'
echo ""
echo "Before publishing, run it on: an Intel Mac, a Mac with no Xcode or"
echo "Homebrew, and an account with Full Disk Access denied. See RELEASING.md."
