#!/bin/bash
#
# Builds, signs, notarizes and packages Attic for direct distribution.
#
#   Tools/release.sh              build, notarize, staple, package
#   Tools/release.sh --check      report what is missing and stop
#   Tools/release.sh --no-notarize    build and package without notarizing
#   Tools/release.sh --friends    a DMG to hand to someone you know, signed
#                                 with whatever certificate is available
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
FRIENDS=0
for argument in "$@"; do
    case "$argument" in
        --check) CHECK_ONLY=1 ;;
        --no-notarize) NOTARIZE=0 ;;
        # For handing to people who know you and will click through one
        # warning. Not for publishing: see the note it prints at the end.
        --friends) FRIENDS=1; NOTARIZE=0 ;;
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
if [ -n "$IDENTITY" ]; then
    echo "signing:        $IDENTITY"
elif [ "$FRIENDS" = 1 ]; then
    # Whatever automatic signing produces. Good enough for a build that goes
    # to three people who will be told what to expect.
    echo "signing:        no Developer ID — using automatic signing"
else
    echo "signing:        MISSING — no Developer ID Application certificate"
    MISSING=1
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

if [ "$FRIENDS" = 1 ] && [ -z "$IDENTITY" ]; then
    step "Taking the app straight out of the archive"
    # `-exportArchive -method developer-id` needs the certificate that is not
    # here. The archived app is already Release-built and hardened, so it is
    # copied rather than re-exported.
    mkdir -p "$EXPORT_DIR"
    cp -R "$ARCHIVE/Products/Applications/$APP_NAME.app" "$EXPORT_DIR/"
else
    step "Exporting with Developer ID"
    xcodebuild -exportArchive -archivePath "$ARCHIVE" \
        -exportOptionsPlist "$BUILD_DIR/export-options.plist" \
        -exportPath "$EXPORT_DIR" -quiet
fi

[ -d "$APP" ] || fail "no app was produced"

# ---------------------------------------------------------------- verify

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"

# Hardened runtime is a notarization requirement, and it is set on Release
# only — so this is also the check that the archive really used Release.
#
# Captured into a variable rather than piped into `grep -q`: grep exits at the
# first match, codesign takes SIGPIPE, and `pipefail` then reports the whole
# pipeline as failed — which made this check reject a perfectly good build.
SIGNATURE=$(codesign -d --verbose=4 "$APP" 2>&1 || true)
case "$SIGNATURE" in
    *"flags=0x10000(runtime)"*) echo "hardened runtime: present" ;;
    *) fail "the app is not built with the hardened runtime" ;;
esac

# The bundle identifier is the one setting that cannot be corrected after the
# first release: macOS keys preferences, the lifetime counter, imported
# definitions and the Full Disk Access grant to it. A stray edit in Xcode's
# Signing & Capabilities pane once shipped a build identified as a fragment of
# the team ID, and every other check here passed — the suite was green, the
# signature was valid, Apple notarized it. So it is checked against a literal.
step "Checking the app is who it claims to be"
EXPECTED_BUNDLE_ID="dev.yogesh.attic"

ACTUAL_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$APP/Contents/Info.plist" 2>/dev/null || true)
[ "$ACTUAL_BUNDLE_ID" = "$EXPECTED_BUNDLE_ID" ] || fail \
    "bundle identifier is '$ACTUAL_BUNDLE_ID', expected '$EXPECTED_BUNDLE_ID' — see RELEASING.md"
echo "bundle id:      $ACTUAL_BUNDLE_ID"

# The signing identifier is derived from the bundle id at signing time, so a
# mismatch here means the two disagree about what this app is.
case "$SIGNATURE" in
    *"Identifier=$EXPECTED_BUNDLE_ID"*) echo "signed as:      $EXPECTED_BUNDLE_ID" ;;
    *) fail "the signature does not identify this app as '$EXPECTED_BUNDLE_ID'" ;;
esac

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

# A notarized-but-unsigned image opens fine, because Gatekeeper reads the
# stapled ticket — but then the ticket is the only thing vouching for it, and
# `spctl` on the download reports "no usable signature". Signing costs one
# command and means the image carries the same identity as the app inside it.
if [ -n "$IDENTITY" ]; then
    step "Signing the disk image"
    codesign --sign "$IDENTITY" --timestamp "$DMG"
    codesign --verify --strict --verbose=2 "$DMG"
fi

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
    #
    # Every step here is fatal on failure. The previous version parsed the
    # mount point out of a tab-separated column and swallowed the verdict with
    # `|| true`, so when the parse came back empty the app was never assessed
    # and the release still reported success.
    xcrun stapler validate "$DMG"

    # The image as a download: what Gatekeeper decides before anything mounts.
    spctl -a -t open --context context:primary-signature -vv "$DMG" \
        || fail "Gatekeeper rejects the disk image"

    MOUNT=$(hdiutil attach "$DMG" -nobrowse -readonly | grep -o '/Volumes/.*$' | tail -1)
    [ -n "$MOUNT" ] || fail "the disk image did not mount, so the app was never assessed"

    # Anything that fails from here needs the image detached first, or the
    # next run inherits a stale mount.
    VERDICT=$(spctl --assess --type execute --verbose=2 "$MOUNT/$APP_NAME.app" 2>&1) \
        || { echo "$VERDICT"; hdiutil detach "$MOUNT" -quiet; fail "Gatekeeper rejects the app inside the image"; }
    echo "$VERDICT"

    MOUNTED_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$MOUNT/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || true)
    hdiutil detach "$MOUNT" -quiet

    [ "$MOUNTED_ID" = "$EXPECTED_BUNDLE_ID" ] || fail \
        "the app inside the image is '$MOUNTED_ID', expected '$EXPECTED_BUNDLE_ID'"
fi

step "Done"
echo "$DMG"
ls -lh "$DMG" | awk '{print "size:", $5}'

if [ "$FRIENDS" = 1 ]; then
    cat <<'NOTE'

This build is NOT notarized. Whoever opens it will see:

    "Apple could not verify Attic is free of malware."

To get past it once, on macOS 15 and later — Control-clicking no longer
works, Apple removed that:

    System Settings → Privacy & Security → scroll down → Open Anyway

Tell them that before you send it, or the first thing your app says to
them is a security warning with no explanation.

NOTE
else
    echo ""
    echo "Before publishing, run it on: an Intel Mac, a Mac with no Xcode or"
    echo "Homebrew, and an account with Full Disk Access denied. See RELEASING.md."
fi
