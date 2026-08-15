#!/bin/bash
#
# setup-spotify.sh — point this build at your own Spotify app, without editing source.
#
#   ./scripts/setup-spotify.sh                       prompts for the client ID
#   ./scripts/setup-spotify.sh <client-id>           non-interactive
#   ./scripts/setup-spotify.sh --show                show what is configured
#   ./scripts/setup-spotify.sh --remove              delete the local configuration
#
# Writes Config/Spotify.plist, which is git-ignored. Nothing here accepts, stores or
# transmits a client secret: this app uses OAuth with PKCE and does not have one.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
TARGET="$ROOT/Config/Spotify.plist"
EXAMPLE="$ROOT/Config/Spotify.example.plist"
REDIRECT_URI="http://127.0.0.1:8888/callback"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

current_id() {
  [ -f "$TARGET" ] || return 1
  /usr/libexec/PlistBuddy -c 'Print :ClientID' "$TARGET" 2>/dev/null || return 1
}

case "${1:-}" in
  --show)
    if id="$(current_id)"; then
      bold "Spotify configuration"
      # Print a masked form: enough to tell two IDs apart, not enough to copy from a
      # screenshot. The ID is not secret, but there is no reason to splash it about.
      ok "Config/Spotify.plist  client ID ${id:0:6}…${id: -4} (${#id} chars)"
      ok "redirect URI to register: $REDIRECT_URI"
    else
      warn "no client ID configured — run ./scripts/setup-spotify.sh"
    fi
    exit 0
    ;;
  --remove)
    [ -f "$TARGET" ] || { warn "nothing to remove"; exit 0; }
    rm -f "$TARGET"
    ok "removed Config/Spotify.plist"
    exit 0
    ;;
  -h|--help)
    sed -n '2,11p' "$0"
    exit 0
    ;;
esac

bold "Spotify setup for Teams Music Status"
echo
echo "You need a free Spotify app of your own. It takes about a minute:"
echo
echo "  1. Open https://developer.spotify.com/dashboard and create an app."
echo "     Any name and description are fine."
echo "  2. Add this redirect URI, exactly as written:"
echo
echo "         $REDIRECT_URI"
echo
echo "     Spotify stopped accepting 'localhost' in November 2025, so it must be the"
echo "     loopback IP literal. A mismatch here is the most common setup failure."
echo "  3. Copy the Client ID (a 32-character hex string)."
echo
echo "Do NOT copy the Client Secret. This app uses PKCE and has no use for one."
echo

CLIENT_ID="${1:-}"
if [ -z "$CLIENT_ID" ]; then
  if existing="$(current_id)" && [ "$existing" != "REPLACE_WITH_YOUR_SPOTIFY_CLIENT_ID" ]; then
    warn "already configured with ${existing:0:6}…${existing: -4}"
    printf "  Replace it? [y/N] "
    read -r reply
    case "$reply" in [yY]*) ;; *) echo "  Keeping the existing configuration."; exit 0 ;; esac
  fi
  printf "Paste your Spotify Client ID: "
  read -r CLIENT_ID
fi

# Trim whitespace people pick up when copying from a browser.
CLIENT_ID="$(printf '%s' "$CLIENT_ID" | tr -d '[:space:]')"

# ── Validation ───────────────────────────────────────────────────────────────
# Catch the mistakes that otherwise surface much later as a confusing OAuth error.
[ -n "$CLIENT_ID" ] || die "no client ID given"

if [ "$CLIENT_ID" = "REPLACE_WITH_YOUR_SPOTIFY_CLIENT_ID" ]; then
  die "that is the placeholder from the example file, not a real client ID"
fi

case "$CLIENT_ID" in
  *:*|*/*|http*)
    die "that looks like a URL, not a client ID. Copy just the Client ID field."
    ;;
esac

if ! printf '%s' "$CLIENT_ID" | grep -qE '^[0-9a-f]{32}$'; then
  LEN=${#CLIENT_ID}
  if printf '%s' "$CLIENT_ID" | grep -qE '^[0-9a-fA-F]{32}$'; then
    # Spotify shows them lowercase; uppercase still works, so normalise rather than reject.
    CLIENT_ID="$(printf '%s' "$CLIENT_ID" | tr '[:upper:]' '[:lower:]')"
    warn "normalised the client ID to lowercase"
  else
    echo >&2
    die "that does not look like a Spotify client ID.
      Expected 32 hexadecimal characters; got $LEN character(s).
      If you copied the Client Secret by mistake, go back and copy the Client ID —
      and note this project never needs the secret."
  fi
fi

# ── Write ────────────────────────────────────────────────────────────────────
mkdir -p "$ROOT/Config"
cat > "$TARGET" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>ClientID</key>
	<string>$CLIENT_ID</string>
</dict>
</plist>
PLIST

plutil -lint "$TARGET" >/dev/null || die "wrote an invalid plist — please report this"
echo
ok "wrote Config/Spotify.plist (${CLIENT_ID:0:6}…${CLIENT_ID: -4})"

# ── Safety checks ────────────────────────────────────────────────────────────
# Belt and braces: confirm the file really is ignored before anyone commits.
if git -C "$ROOT" check-ignore -q "$TARGET" 2>/dev/null; then
  ok "git-ignored, so it cannot be committed by accident"
else
  warn "Config/Spotify.plist is NOT git-ignored — check .gitignore before committing"
fi

if [ -f "$EXAMPLE" ] && ! git -C "$ROOT" check-ignore -q "$EXAMPLE" 2>/dev/null; then
  ok "Config/Spotify.example.plist stays committed as the template"
fi

echo
bold "Next"
echo "  1. Confirm $REDIRECT_URI is registered on your Spotify app."
echo "  2. Build and run:   ./scripts/build-app.sh --run"
echo "  3. In the app's setup window, choose Connect Spotify."
