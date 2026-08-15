#!/bin/bash
#
# build-app.sh — assemble and sign a DEVELOPMENT TeamsMusicStatus.app.
#
# For distribution use scripts/release.sh instead: this script makes a debug build,
# signs with whatever local certificate is handy, and does not notarize.
#
#   ./scripts/build-app.sh                 debug build
#   ./scripts/build-app.sh --release       optimised build
#   ./scripts/build-app.sh --run           build, then launch
#
# Version, bundle identity, entitlements and the Spotify client ID all come from
# scripts/common.sh so this and release.sh cannot drift apart.
#
# Signing: uses $CODESIGN_IDENTITY, else the first Apple Development identity.
# A STABLE identity matters — re-signing ad hoc changes the code requirement and macOS
# silently drops the Accessibility permission, forcing you to re-grant it every build.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
cd "$ROOT"

CONFIG="debug"
RUN=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG="release" ;;
    --run) RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

read_version
resolve_client_id
APP_NAME="$DEV_APP_NAME"

if [ -z "$CLIENT_ID" ]; then
  echo "==> WARNING: no Spotify client ID found."
  echo "    The app will start, but 'Connect Spotify' will be unavailable."
  echo "    Set SPOTIFY_CLIENT_ID, or create Config/Spotify.plist with a ClientID key."
else
  echo "==> Spotify client ID found (${#CLIENT_ID} chars)"
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product "$EXECUTABLE_NAME"
BINARY="$(swift build -c "$CONFIG" --product "$EXECUTABLE_NAME" --show-bin-path)/$EXECUTABLE_NAME"
[ -x "$BINARY" ] || { echo "build produced no binary at $BINARY" >&2; exit 1; }

APP_DIR="$ROOT/build/$APP_NAME"
echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
write_info_plist "$APP_DIR/Contents/Info.plist"
[ -f "$ICON_ICNS" ] && cp "$ICON_ICNS" "$APP_DIR/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# ---- signing -----------------------------------------------------------------
#
# The entitlements file must stay bare XML with no comments: codesign hands it to
# AMFI, whose parser is stricter than plutil and fails on a comment block with
# "AMFIUnserializeXML: syntax error". A silent failure here is expensive, because the
# app then runs WITHOUT com.apple.security.automation.apple-events and macOS refuses
# every Apple Event with -1743 and never prompts -- which is indistinguishable from
# the user having denied Automation access.
#
# The entitlement is needed because we sign with the hardened runtime. Without it the
# Local Spotify source and the AppleScript window-reopen fallback cannot work.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  # Select by SHA-1 hash, not by name: the same certificate name can appear in more
  # than one keychain, and codesign then refuses with "ambiguous". The hash also keeps
  # the developer's name and email out of the build log.
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 'Apple Development' | awk '{print $2}' || true)"
fi

if [ -n "$IDENTITY" ]; then
  echo "==> codesign with identity ${IDENTITY:0:8}…"
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" "$APP_DIR" 2>&1 | sed 's/^/    /'
else
  echo "==> no signing identity found; signing ad hoc"
  echo "    NOTE: macOS may drop the Accessibility grant on every rebuild."
  echo "    Set CODESIGN_IDENTITY to a stable certificate to avoid re-granting."
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR" 2>&1 | sed 's/^/    /'
fi

codesign --verify --verbose=1 "$APP_DIR" 2>&1 | sed 's/^/    /'
echo "==> built $APP_DIR"

if [ "$RUN" = "1" ]; then
  echo "==> launching"
  # Kill a previous instance so the new binary is the one holding the menu bar item.
  pkill -f "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME" 2>/dev/null || true
  sleep 0.5
  open "$APP_DIR"
fi
