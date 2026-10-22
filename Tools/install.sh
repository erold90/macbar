#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Installs the latest MacBar release from GitHub, checking it first.
#
#   ./Tools/install.sh                     install the newest release
#   ./Tools/install.sh --stable-signing    also keep granted permissions across updates
#   ./Tools/install.sh --version v3.4.2-beta.2
#   ./Tools/install.sh --dest ~/Applications
#
# What it does, in order:
#   1. finds the release and its .sha256 file (nothing is run from the download)
#   2. downloads both and checks the SHA-256, then the code signature
#   3. quits a running MacBar, replaces the app, clears the download quarantine flag
#   4. with --stable-signing, re-signs the installed copy with a local self-signed
#      identity (created once by Tools/setup-signing.sh, in its own keychain).
#
# Why --stable-signing exists: the release is signed ad hoc, which gives every
# build a different signature, and macOS then forgets the Accessibility and Screen
# Recording permissions after each update. A local identity is the same on every
# update, so the permissions stay. It is free and offline, and it only changes
# the signature of the copy on this Mac. It is not notarization: macOS still shows
# its "unverified developer" prompt the first time (right-click the app, Open).
set -euo pipefail

REPO="erold90/macbar"
APP_NAME="MacBar"
BUNDLE_ID="com.erold90.macbar"
IDENTITY="MacBar Local Signing"
KEYCHAIN="$HOME/Library/Keychains/macbar-signing.keychain-db"

DEST="/Applications"
VERSION=""
STABLE=0

while (( $# )); do
    case "$1" in
        --stable-signing) STABLE=1 ;;
        --version) shift; VERSION="${1:-}"; [[ -n "$VERSION" ]] || { echo "✗ --version needs a tag" >&2; exit 2; } ;;
        --dest) shift; DEST="${1:-}"; [[ -d "$DEST" ]] || { echo "✗ --dest must be an existing folder" >&2; exit 2; } ;;
        -h|--help) sed -n '4,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "✗ unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

die() { echo "✗ $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "MacBar runs on macOS only."
ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" ]] || die "this release is built for Intel Macs (x86_64); this Mac is $ARCH. Build from source: see the README."
(( $(sw_vers -productVersion | cut -d. -f1) >= 14 )) || die "macOS 14 or newer is required."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Find the release. The API answer is parsed as JSON by the system, not evaluated.
if [[ -n "$VERSION" ]]; then
    API="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
else
    API="https://api.github.com/repos/$REPO/releases?per_page=1"
fi
echo "▸ Looking up the release…"
curl -fsSL -H "Accept: application/vnd.github+json" "$API" -o "$WORK/release.json" \
    || die "could not reach GitHub ($API)."
PREFIX=""; [[ -n "$VERSION" ]] || PREFIX="0."
TAG="$(plutil -extract "${PREFIX}tag_name" raw -o - "$WORK/release.json" 2>/dev/null)" || die "no release found."
ZIP_URL="" ; SUM_URL=""
i=0
while URL="$(plutil -extract "${PREFIX}assets.$i.browser_download_url" raw -o - "$WORK/release.json" 2>/dev/null)"; do
    case "$URL" in
        *"-intel-x86_64.zip") ZIP_URL="$URL" ;;
        *"-intel-x86_64.zip.sha256") SUM_URL="$URL" ;;
    esac
    i=$((i + 1))
done
[[ -n "$ZIP_URL" && -n "$SUM_URL" ]] || die "release $TAG has no Intel zip with a .sha256 file."
case "$ZIP_URL$SUM_URL" in
    "https://github.com/$REPO/releases/download/"*) ;;
    *) die "unexpected download address; stopping." ;;
esac

# 2. Download and verify.
ZIP="$WORK/$(basename "$ZIP_URL")"
echo "▸ Downloading $TAG…"
PROGRESS=(-sS); [[ -t 2 ]] && PROGRESS=(--progress-bar)
curl -fL "${PROGRESS[@]}" "$ZIP_URL" -o "$ZIP"
curl -fsSL "$SUM_URL" -o "$WORK/expected.sha256"
EXPECTED="$(awk '{print $1; exit}' "$WORK/expected.sha256")"
ACTUAL="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
[[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] || die "the checksum file is not a SHA-256."
[[ "$EXPECTED" == "$ACTUAL" ]] || die "checksum mismatch — the download is not the published file. Nothing was installed."
echo "✓ SHA-256 matches ($ACTUAL)"

mkdir "$WORK/unpacked"
ditto -x -k "$ZIP" "$WORK/unpacked"
NEW_APP="$WORK/unpacked/$APP_NAME.app"
[[ -d "$NEW_APP" ]] || die "the archive does not contain $APP_NAME.app."
codesign --verify --deep --strict "$NEW_APP" 2>/dev/null || die "the app's signature does not verify. Nothing was installed."
FOUND_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NEW_APP/Contents/Info.plist")"
[[ "$FOUND_ID" == "$BUNDLE_ID" ]] || die "unexpected bundle identifier ($FOUND_ID)."
echo "✓ Signature and bundle identifier check out"

# 3. Replace the app.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "▸ Quitting the running $APP_NAME…"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in {1..10}; do pgrep -x "$APP_NAME" >/dev/null 2>&1 || break; sleep 1; done
    pgrep -x "$APP_NAME" >/dev/null 2>&1 && die "$APP_NAME is still running; quit it and try again."
fi
TARGET="$DEST/$APP_NAME.app"
[[ -e "$TARGET" ]] && rm -rf "$TARGET"
ditto "$NEW_APP" "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
echo "✓ Installed $TARGET"

# 4. Optional: a signature that survives updates.
if (( STABLE )); then
    SETUP="${0:A:h}/setup-signing.sh"
    [[ -x "$SETUP" ]] || die "--stable-signing needs Tools/setup-signing.sh next to this script (clone the repository)."
    echo "▸ Preparing the local signing identity…"
    "$SETUP"
    security unlock-keychain -p "macbar-signing" "$KEYCHAIN" 2>/dev/null || true
    HELPER="$TARGET/Contents/Library/LaunchServices/$BUNDLE_ID.fan-control"
    ADAPTER="$TARGET/Contents/Frameworks/libMacBarNowPlaying.dylib"
    [[ -f "$HELPER" ]]  && codesign --force --strip-disallowed-xattrs --identifier "$BUNDLE_ID.fan-control" --sign "$IDENTITY" "$HELPER"
    [[ -f "$ADAPTER" ]] && codesign --force --strip-disallowed-xattrs --identifier "$BUNDLE_ID.now-playing" --sign "$IDENTITY" "$ADAPTER"
    codesign --force --strip-disallowed-xattrs --sign "$IDENTITY" "$TARGET"
    codesign --verify --deep --strict "$TARGET" || die "re-signing failed; the app was left installed with the release signature."
    echo "✓ Signed with the local identity: permissions will survive future updates"
else
    echo
    echo "Note: this build is signed ad hoc, so macOS asks for Accessibility and Screen"
    echo "Recording again after each update. Run with --stable-signing (from a clone of"
    echo "the repository) to keep them."
fi

echo
echo "Done. First launch: right-click $APP_NAME.app in $DEST, choose Open."
