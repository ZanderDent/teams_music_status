#!/bin/bash
#
# release.sh — build, sign, package and notarize a distributable Teams Music Status.
#
#   ./scripts/release.sh                 auto: sign with Developer ID if one exists
#   ./scripts/release.sh --unsigned      skip signing entirely (local testing only)
#   ./scripts/release.sh --signed        require a Developer ID signature; fail without
#   ./scripts/release.sh --notarize      --signed, plus notarize and staple
#   ./scripts/release.sh --dev-signed    sign with an Apple Development certificate.
#                                        LOCAL VERIFICATION ONLY — Apple Development
#                                        certificates cannot be notarized, and Gatekeeper
#                                        rejects the result on any other Mac. This exists
#                                        so hardened-runtime and entitlement behaviour can
#                                        be exercised before a Developer ID is available.
#   ./scripts/release.sh --arch arm64    build one slice instead of Universal 2
#
# Environment:
#   DEVELOPER_ID_APPLICATION   full identity name or SHA-1 hash, if auto-discovery is
#                              ambiguous or you want to pin one
#   NOTARY_PROFILE             notarytool keychain profile name (default below)
#   SPOTIFY_CLIENT_ID          overrides Config/Spotify.plist and .env
#
# Nothing here reads, writes or logs a credential. Notarization uses a keychain profile
# created by `xcrun notarytool store-credentials`, so no password ever appears in a
# command line, an environment variable, or this repository.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
cd "$ROOT"

NOTARY_PROFILE="${NOTARY_PROFILE:-teams-music-status}"

MODE="auto"          # auto | unsigned | signed | notarize
ARCHS="universal"    # universal | arm64 | x86_64
SKIP_TESTS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --unsigned) MODE="unsigned" ;;
    --dev-signed) MODE="dev-signed" ;;
    --signed)   MODE="signed" ;;
    --notarize) MODE="notarize" ;;
    --arch)     shift; ARCHS="${1:-universal}" ;;
    --skip-tests) SKIP_TESTS=1 ;;   # for iterating on packaging only
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# ── Output ───────────────────────────────────────────────────────────────────
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()    { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()   { printf '    \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

read_version
resolve_client_id

# A public build must not carry the maintainer's Spotify client ID.
#
# `resolve_client_id` finds Config/Spotify.plist and .env, which exist on a maintainer's
# machine for development. Shipping what it finds would put one person's credential in
# every download — and it would not even help: Spotify serves five hand-allowlisted
# accounts per development-mode app and refuses everyone else with a 403.
#
# So distributable modes drop it unless the operator explicitly asks otherwise. Set
# EMBED_SPOTIFY_CLIENT_ID=1 only for a private build of your own.
case "$MODE" in
  signed|notarize)
    if [ -n "${CLIENT_ID:-}" ] && [ "${EMBED_SPOTIFY_CLIENT_ID:-0}" != "1" ]; then
      CLIENT_ID=""
      export CLIENT_ID
    fi
    ;;
esac

DIST="$ROOT/dist"
STAGE="$ROOT/dist/stage"
APP="$STAGE/$RELEASE_APP_NAME"
DMG_NAME="Teams-Music-Status-${MARKETING_VERSION}-macOS.dmg"
DMG="$DIST/$DMG_NAME"

bold "Teams Music Status $MARKETING_VERSION (build $BUILD_NUMBER)"
echo "mode: $MODE    arch: $ARCHS"

# ── Preflight ────────────────────────────────────────────────────────────────
step "Preflight"

# The deployment target lives in two places by necessity (Package.swift compiles it,
# Info.plist declares it). Assert they agree rather than letting them drift.
PKG_PLATFORM="$(grep -oE '\.macOS\(\.v[0-9]+\)' Package.swift | head -1 | grep -oE '[0-9]+')"
[ "${PKG_PLATFORM:-}" = "${MIN_MACOS%%.*}" ] \
  || die "Package.swift targets macOS $PKG_PLATFORM but common.sh declares $MIN_MACOS"
ok "deployment target consistent (macOS $MIN_MACOS)"

[ -f "$ICON_ICNS" ] || die "missing app icon at $ICON_ICNS — run: python3 Assets/AppIcon/make-icon.py && iconutil -c icns Assets/AppIcon/AppIcon.iconset -o $ICON_ICNS"
ok "app icon present"

[ -f "$ENTITLEMENTS" ] || die "missing entitlements at $ENTITLEMENTS"
# codesign hands this to AMFI, whose parser rejects comments. A malformed file is
# silently ignored, producing an app with NO entitlements — which breaks the Local
# Spotify source in a way that looks like the user denied permission.
plutil -lint "$ENTITLEMENTS" >/dev/null || die "entitlements file is not valid plist"
grep -q '<!--' "$ENTITLEMENTS" && die "entitlements must not contain XML comments; AMFI rejects them and codesign then signs with none"
ok "entitlements valid and comment-free"

# A Spotify client ID is OPTIONAL, and public builds ship without one.
#
# It used to be fatal to build without it, because the Web API was the default source.
# It no longer is: Spotify caps a development-mode app at five hand-allowlisted accounts,
# and extended quota is open only to registered organisations with 250k monthly actives,
# so a bundled client ID cannot serve the public however it is packaged — it would just
# fail with a 403 for everyone past the fifth person.
#
# The default source reads the local Spotify app, which needs no credential at all. The
# Web API remains available to anyone who supplies their own client ID in a build of
# their own, which is the only arrangement Spotify's rules actually permit.
if [ -z "$CLIENT_ID" ]; then
  ok "no Spotify client ID embedded (local Spotify source needs none)"
else
  warn "embedding a Spotify client ID (${#CLIENT_ID} chars) — do NOT do this for a public release"
  warn "a bundled client ID serves at most 5 allowlisted Spotify accounts"
fi

GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY=""
if ! git diff --quiet HEAD 2>/dev/null; then
  GIT_DIRTY=" (uncommitted changes)"
  warn "working tree has uncommitted changes; the release will not be reproducible from git"
fi
ok "git $GIT_COMMIT$GIT_DIRTY"

# ── Signing identity discovery ───────────────────────────────────────────────
# Apple Development and Mac App Distribution certificates cannot be notarized and must
# never be presented as a public release. Only Developer ID Application qualifies.
SIGN_IDENTITY=""
discover_identity() {
  if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
    SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
    return 0
  fi
  local found
  found="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' || true)"
  local count
  count="$(printf '%s' "$found" | grep -c . || true)"
  if [ "$count" -eq 0 ]; then
    return 1
  elif [ "$count" -gt 1 ]; then
    echo "$found" | sed 's/^/      /' >&2
    die "multiple Developer ID Application identities found. Set DEVELOPER_ID_APPLICATION to the one you want (name or SHA-1 hash)."
  fi
  # Prefer the SHA-1 hash: the same certificate name can exist in more than one
  # keychain, and codesign then fails as "ambiguous".
  SIGN_IDENTITY="$(printf '%s' "$found" | awk '{print $2}')"
}

step "Signing identity"
if [ "$MODE" = "unsigned" ]; then
  warn "unsigned build requested — for local testing only, not for distribution"
elif [ "$MODE" = "dev-signed" ]; then
  # Deliberately separate from --signed so a development-signed artifact can never be
  # mistaken for, or accidentally published as, a release.
  DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Development' | head -1 | awk '{print $2}' || true)"
  [ -n "$DEV_ID" ] || die "no Apple Development certificate found either"
  SIGN_IDENTITY="$DEV_ID"
  warn "signing with an APPLE DEVELOPMENT certificate — verification only"
  warn "this cannot be notarized and Gatekeeper will reject it on other Macs"
elif discover_identity; then
  ok "Developer ID Application: ${SIGN_IDENTITY:0:12}…"
else
  if [ "$MODE" = "signed" ] || [ "$MODE" = "notarize" ]; then
    cat >&2 <<'BLOCKED'
    ✗ No "Developer ID Application" certificate is installed.

      Apple Development certificates CANNOT be notarized and must not be shipped.

      To obtain one (requires a paid Apple Developer Program membership):
        1. https://developer.apple.com/account → Certificates, IDs & Profiles
        2. Certificates → + → "Developer ID Application"
        3. Follow the CSR steps, download the .cer, double-click to install
        4. Confirm with: security find-identity -v -p codesigning

      Then re-run this script.
BLOCKED
    exit 1
  fi
  MODE="unsigned"
  warn "no Developer ID Application certificate; falling back to an UNSIGNED build"
  warn "this artifact is NOT distributable — see docs/DISTRIBUTION.md"
fi

# ── Clean ────────────────────────────────────────────────────────────────────
step "Clean"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST"
ok "staging area reset"

# ── Tests ────────────────────────────────────────────────────────────────────
if [ "$SKIP_TESTS" = "0" ]; then
  step "Tests"
  swift test 2>&1 | tail -3 | sed 's/^/    /'
  ok "unit tests passed"
else
  warn "tests skipped (--skip-tests)"
fi

# ── Release build ────────────────────────────────────────────────────────────
step "Release build"
build_slice() {
  local triple="$1"
  swift build -c release --product "$EXECUTABLE_NAME" --triple "$triple" >/dev/null
  echo "$ROOT/.build/${triple%%-apple*}-apple-macosx/release/$EXECUTABLE_NAME"
}

case "$ARCHS" in
  universal)
    ARM_BIN="$(build_slice "arm64-apple-macosx$MIN_MACOS")"
    ok "arm64 slice built"
    X86_BIN="$(build_slice "x86_64-apple-macosx$MIN_MACOS")"
    ok "x86_64 slice built"
    ;;
  arm64)   ARM_BIN="$(build_slice "arm64-apple-macosx$MIN_MACOS")"; X86_BIN=""; ok "arm64 built" ;;
  x86_64)  X86_BIN="$(build_slice "x86_64-apple-macosx$MIN_MACOS")"; ARM_BIN=""; ok "x86_64 built" ;;
  *) die "unknown --arch '$ARCHS' (use universal, arm64 or x86_64)" ;;
esac

# ── Assemble the bundle ──────────────────────────────────────────────────────
step "Assemble $RELEASE_APP_NAME"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ -n "$ARM_BIN" ] && [ -n "$X86_BIN" ]; then
  lipo -create "$ARM_BIN" "$X86_BIN" -output "$APP/Contents/MacOS/$EXECUTABLE_NAME"
else
  cp "${ARM_BIN:-$X86_BIN}" "$APP/Contents/MacOS/$EXECUTABLE_NAME"
fi
chmod +x "$APP/Contents/MacOS/$EXECUTABLE_NAME"
ARCH_LIST="$(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE_NAME")"
ok "binary: $ARCH_LIST"

# Release binaries carry debug symbols from the Swift compiler by default. Stripping
# them shrinks the download and removes build-machine paths from the shipped Mach-O.
strip -rSTx "$APP/Contents/MacOS/$EXECUTABLE_NAME" 2>/dev/null || warn "strip failed; continuing"
ok "symbols stripped"

write_info_plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "generated Info.plist is invalid"
cp "$ICON_ICNS" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
ok "Info.plist, icon and PkgInfo written"

# ── Sign ─────────────────────────────────────────────────────────────────────
# Inside-out, explicitly. `codesign --deep` is not used: it is documented by Apple as
# unsuitable for signing for distribution, silently applies the outer entitlements to
# nested code, and hides structural problems rather than reporting them.
step "Sign"
if [ "$MODE" = "unsigned" ]; then
  warn "skipping signature"
else
  # Enumerate genuinely nested code rather than assuming there is none.
  NESTED="$(find "$APP/Contents" -type f -perm -u+x ! -path "*/MacOS/$EXECUTABLE_NAME" 2>/dev/null || true)"
  NESTED_BUNDLES="$(find "$APP/Contents" \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' -o -name '*.appex' -o -name '*.xpc' \) 2>/dev/null || true)"
  if [ -n "$NESTED$NESTED_BUNDLES" ]; then
    echo "$NESTED$NESTED_BUNDLES" | sed 's/^/      /'
    for item in $NESTED_BUNDLES $NESTED; do
      codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$item"
    done
    ok "nested code signed first"
  else
    ok "no nested code (single static executable) — nothing to sign first"
  fi

  codesign --force --sign "$SIGN_IDENTITY" \
           --options runtime \
           --timestamp \
           --entitlements "$ENTITLEMENTS" \
           "$APP"
  ok "app signed with hardened runtime and secure timestamp"
fi

# ── Verify signature ─────────────────────────────────────────────────────────
step "Verify"
if [ "$MODE" != "unsigned" ]; then
  codesign --verify --deep --strict --verbose=4 "$APP" 2>&1 | sed 's/^/    /'
  ok "codesign --verify --deep --strict passed"

  # Capture once and inspect the string. Piping `codesign` into `grep -q` looks natural
  # but is a trap under `set -o pipefail`: grep exits on the first match, codesign takes
  # SIGPIPE, and the pipeline reports failure even though the check passed.
  CODESIGN_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
  echo "$CODESIGN_INFO" | grep -E 'Identifier|Authority|TeamIdentifier|flags|Timestamp' | sed 's/^/    /'

  # Trust the SIGNED bundle, not the source file: a malformed entitlements plist is
  # ignored by AMFI and produces an app with none, with no error anywhere.
  SIGNED_ENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)"
  echo "$SIGNED_ENTS" | grep -q 'com.apple.security.automation.apple-events' \
    || die "signed bundle is MISSING com.apple.security.automation.apple-events — the Local Spotify source and the Teams window-reopen fallback would silently fail"
  ok "apple-events entitlement present in the signed binary"

  case "$CODESIGN_INFO" in
    *"flags=0x10000(runtime)"*|*"(runtime)"*) ;;
    *) die "hardened runtime is not enabled on the signed bundle" ;;
  esac
  ok "hardened runtime enabled"
else
  warn "unsigned: signature verification skipped"
fi

# Structural checks that apply either way.
/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist" | grep -q true \
  || die "LSUIElement missing — the app would show a Dock icon"
ok "LSUIElement intact (menu-bar only)"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "$BUNDLE_ID" ] \
  || die "bundle identifier mismatch"
ok "bundle identifier $BUNDLE_ID"

# ── Notarize ─────────────────────────────────────────────────────────────────
NOTARY_STATUS="not attempted"
NOTARY_ID=""
if [ "$MODE" = "notarize" ]; then
  step "Notarize"
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat >&2 <<BLOCKED
    ✗ No notarytool credentials found for profile "$NOTARY_PROFILE".

      Create one (stored in your Keychain, never in this repository):

        xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
          --apple-id "<your Apple ID email>" \\
          --team-id "<your 10-character Team ID>" \\
          --password "<an app-specific password>"

      Generate the app-specific password at https://account.apple.com → Sign-In and
      Security → App-Specific Passwords. It is not your Apple ID password.
BLOCKED
    exit 1
  fi
  ok "notarytool credentials found"

  # Notarize and staple the *app* before it goes into the DMG, then notarize and staple
  # the DMG afterwards. Both are required, and stapling only the DMG is the subtle
  # mistake: the ticket then lives on the container, not on the bundle. A user who drags
  # the app to /Applications gets a copy carrying a quarantine flag and no ticket, so
  # Gatekeeper has to ask Apple over the network at first launch. On a machine that is
  # offline — or behind a filter that blocks Apple's OCSP endpoint — that check fails and
  # the app is refused with "Apple could not verify it is free of malware", on a build
  # that is in fact perfectly notarized. Stapling the bundle is what makes it work with
  # no network at all.
  step "Notarize the app"
  APP_ZIP="$STAGE/app-for-notarization.zip"
  rm -f "$APP_ZIP"
  /usr/bin/ditto -c -k --keepParent "$APP" "$APP_ZIP"
  APP_SUBMIT_LOG="$STAGE/notary-submit-app.txt"
  set +e
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
    --output-format json > "$APP_SUBMIT_LOG" 2>&1
  APP_SUBMIT_RC=$?
  set -e
  APP_NOTARY_ID="$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("id",""))' "$APP_SUBMIT_LOG" 2>/dev/null || true)"
  APP_NOTARY_STATUS="$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("status",""))' "$APP_SUBMIT_LOG" 2>/dev/null || true)"
  echo "    submission: ${APP_NOTARY_ID:-unknown}    status: ${APP_NOTARY_STATUS:-unknown}"
  if [ "$APP_NOTARY_STATUS" != "Accepted" ] || [ $APP_SUBMIT_RC -ne 0 ]; then
    warn "app notarization did not succeed — fetching the log"
    [ -n "$APP_NOTARY_ID" ] && xcrun notarytool log "$APP_NOTARY_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 | sed 's/^/    /'
    die "app notarization failed with status '${APP_NOTARY_STATUS:-unknown}'. This is NOT a releasable artifact."
  fi
  rm -f "$APP_ZIP"
  xcrun stapler staple "$APP" 2>&1 | sed 's/^/    /'
  xcrun stapler validate "$APP" 2>&1 | sed 's/^/    /'
  ok "app notarized and stapled — it launches offline once copied out of the DMG"
fi

# ── DMG ──────────────────────────────────────────────────────────────────────
step "Package DMG"
rm -f "$DMG"
DMG_ROOT="$STAGE/dmgroot"
rm -rf "$DMG_ROOT"; mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
ok "staged app + Applications alias"

VOLNAME="Teams Music Status $MARKETING_VERSION"
RW_DMG="$STAGE/rw.dmg"
rm -f "$RW_DMG"
hdiutil create -srcfolder "$DMG_ROOT" -volname "$VOLNAME" -fs HFS+ \
  -format UDRW -ov "$RW_DMG" >/dev/null
ok "read-write image created"

# Finder layout: window size, icon positions and the background with its arrow.
#
# Best-effort by design. It drives Finder over Apple Events, which a fresh machine or a
# CI runner has no permission for, and a plain but correct DMG beats a failed release.
# The warning is loud though, because an unstyled DMG is the first thing every user sees:
# icons land wherever Finder feels like, in the wrong order, with no arrow.
# Mount at the DEFAULT location, not a temporary directory.
#
# This cost the DMG its layout for every release built so far. Finder's `disk "NAME"`
# only resolves volumes under /Volumes, so mounting at a mktemp path made every layout
# attempt fail with "Can't get disk" (-1728) — which the code then reported as missing
# Automation permission. The permission was never the problem, and the misleading warning
# is why it went unfixed: the DMG shipped with icons wherever Finder felt like putting
# them, in the wrong order, with no arrow.
#
# -nobrowse is dropped for the same reason: it hides the volume from Finder.
hdiutil detach "/Volumes/$VOLNAME" -force >/dev/null 2>&1 || true
MOUNT_DIR="/Volumes/$VOLNAME"
if hdiutil attach "$RW_DMG" -noautoopen >/dev/null 2>&1; then
  # Finder needs a moment to notice a freshly mounted volume.
  sleep 2
  # The background has to live inside the image, and hidden, or it shows up as a file in
  # the window next to the app.
  if [ -f "$DMG_BACKGROUND" ]; then
    mkdir -p "$MOUNT_DIR/.background"
    cp "$DMG_BACKGROUND" "$MOUNT_DIR/.background/background.tiff"
  fi
  if osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 150, 800, 570}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set background picture of theViewOptions to file ".background:background.tiff"
    set position of item "$RELEASE_APP_NAME" of container window to {150, 200}
    set position of item "Applications" of container window to {450, 200}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
  then
    ok "Finder layout applied"
  else
    warn "could not set the Finder layout; the DMG is valid but will look unstyled. Check Automation permission for Finder, and that /Volumes/$VOLNAME mounted."
  fi
  sync
  hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
else
  warn "could not mount the image to apply a layout; continuing"
fi
rmdir "$MOUNT_DIR" 2>/dev/null || true

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW_DMG"
ok "compressed DMG: $DMG_NAME"

if [ "$MODE" != "unsigned" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  ok "DMG signed"
fi

# ── Notarize + staple the DMG ────────────────────────────────────────────────
if [ "$MODE" = "notarize" ]; then
  step "Submit to Apple notary service"
  SUBMIT_LOG="$STAGE/notary-submit.txt"
  set +e
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
    --output-format json > "$SUBMIT_LOG" 2>&1
  SUBMIT_RC=$?
  set -e
  NOTARY_ID="$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("id",""))' "$SUBMIT_LOG" 2>/dev/null || true)"
  NOTARY_STATUS="$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("status",""))' "$SUBMIT_LOG" 2>/dev/null || true)"
  echo "    submission: ${NOTARY_ID:-unknown}    status: ${NOTARY_STATUS:-unknown}"

  if [ "$NOTARY_STATUS" != "Accepted" ] || [ $SUBMIT_RC -ne 0 ]; then
    warn "notarization did not succeed — fetching the log"
    [ -n "$NOTARY_ID" ] && xcrun notarytool log "$NOTARY_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 | sed 's/^/    /'
    die "notarization failed with status '${NOTARY_STATUS:-unknown}'. This is NOT a releasable artifact."
  fi
  ok "notarization Accepted"

  step "Staple"
  xcrun stapler staple "$DMG" 2>&1 | sed 's/^/    /'
  xcrun stapler validate "$DMG" 2>&1 | sed 's/^/    /'
  ok "ticket stapled and validated — the DMG works offline"

  # Guard against shipping a DMG whose ticket is only on the container. Without this the
  # regression is invisible: every online check still passes, and only a user installing
  # without network ever sees it.
  if xcrun stapler validate "$APP" >/dev/null 2>&1; then
    ok "the app inside the DMG carries its own ticket too"
  else
    die "the app has no stapled ticket. It would fail Gatekeeper on an offline first launch."
  fi
fi

# ── Gatekeeper ───────────────────────────────────────────────────────────────
step "Gatekeeper assessment"
GK_APP="$(spctl --assess --type execute --verbose=4 "$APP" 2>&1 || true)"
echo "$GK_APP" | sed 's/^/    /'
GK_DMG="$(spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" 2>&1 || true)"
echo "$GK_DMG" | sed 's/^/    /'
if echo "$GK_APP" | grep -q 'accepted'; then
  ok "app accepted by Gatekeeper"
else
  warn "app NOT accepted by Gatekeeper (expected for an unsigned or un-notarized build)"
fi

# ── Checksums and metadata ───────────────────────────────────────────────────
step "Checksums and release metadata"
( cd "$DIST" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256" )
SHA="$(awk '{print $1}' "$DMG.sha256")"
DMG_SIZE="$(du -h "$DMG" | awk '{print $1}')"
ok "sha256 $SHA"

SIGN_DESC="unsigned"
TEAM_ID=""
# An unsigned bundle carries NO entitlements — they are embedded by codesign. Saying
# otherwise in the metadata would misrepresent what the artifact can actually do.
ENTS_DESC="none (unsigned; entitlements are applied at signing)"
if [ "$MODE" != "unsigned" ]; then
  ENTS_DESC="$(printf '%s' "$SIGNED_ENTS" | grep -oE 'com\.apple\.security[a-z.\-]*' | paste -sd, - || echo unknown)"
  SIGN_DESC="$(printf '%s' "$CODESIGN_INFO" | grep '^Authority=' | head -1 | cut -d= -f2- || true)"
  TEAM_ID="$(printf '%s' "$CODESIGN_INFO" | grep '^TeamIdentifier=' | cut -d= -f2- || true)"
fi

cat > "$DIST/release-info.txt" <<INFO
Teams Music Status — release metadata

product            : Teams Music Status
version            : $MARKETING_VERSION
build              : $BUILD_NUMBER
bundle identifier  : $BUNDLE_ID
architectures      : $ARCH_LIST
minimum macOS      : $MIN_MACOS
git commit         : $GIT_COMMIT$GIT_DIRTY
built              : $(date -u '+%Y-%m-%dT%H:%M:%SZ')

signing identity   : $SIGN_DESC
team identifier    : ${TEAM_ID:-n/a}
hardened runtime   : $([ "$MODE" != "unsigned" ] && echo enabled || echo "n/a (unsigned)")
entitlements       : $ENTS_DESC

notarization       : $NOTARY_STATUS
submission id      : ${NOTARY_ID:-n/a}
stapled            : $([ "$MODE" = "notarize" ] && echo yes || echo no)

artifact           : $DMG_NAME
size               : $DMG_SIZE
sha256             : $SHA
INFO
ok "dist/release-info.txt written"

# ── Summary ──────────────────────────────────────────────────────────────────
echo
if [ "$MODE" = "notarize" ] && [ "$NOTARY_STATUS" = "Accepted" ]; then
  bold "RELEASE READY — signed, notarized and stapled"
  echo "  $DMG"
elif [ "$MODE" = "dev-signed" ]; then
  bold "DEVELOPMENT-SIGNED BUILD — verification only, NOT distributable"
  echo "  $DMG"
  echo "  Apple Development certificates cannot be notarized. Obtain a Developer ID"
  echo "  Application certificate and re-run with --notarize to publish."
elif [ "$MODE" != "unsigned" ]; then
  bold "SIGNED BUILD (not notarized)"
  echo "  $DMG"
  echo "  Run with --notarize to produce a publicly distributable artifact."
else
  bold "UNSIGNED BUILD — local testing only, NOT for distribution"
  echo "  $DMG"
  echo "  Users would see \"cannot be opened because the developer cannot be verified\"."
fi
echo "  sha256: $SHA"
