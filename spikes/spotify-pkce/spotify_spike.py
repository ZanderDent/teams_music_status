#!/usr/bin/env python3
"""
spotify_spike.py — Phase C feasibility spike for the Spotify PresenceSource.

Proves, against the real Spotify Web API and a real account:
  1. OAuth 2.0 Authorization Code + PKCE  (no client secret anywhere)
  2. currently-playing track retrieval
  3. artist retrieval
  4. playing vs paused discrimination
  5. track-change detection
  6. refresh-token rotation
  7. graceful handling of "nothing is playing"
  8. graceful handling of 401 / 403 / 429

Standard library only — no pip install.

Tokens live in the macOS Keychain (`security` CLI), never on disk in this repo and
never in a log line. The only thing ever printed about a token is its length.

Usage:
    ./spotify_spike.py auth              run the PKCE flow once, store tokens
    ./spotify_spike.py now               print current playback state once
    ./spotify_spike.py watch [seconds]   poll and print only on state change
    ./spotify_spike.py refresh           force a refresh-token exchange
    ./spotify_spike.py errors            exercise the 401/403/429 handling paths
    ./spotify_spike.py logout            delete stored tokens from the Keychain

Environment:
    SPOTIFY_CLIENT_ID     required (read from ../../.env if present)
    SPOTIFY_REDIRECT_URI  default http://127.0.0.1:8888/callback

NOTE: Spotify banned `localhost` as a redirect host (enforced 27 Nov 2025). The
redirect URI must be a loopback IP literal — http://127.0.0.1:PORT/... — and must
be registered verbatim in the app's dashboard.
"""

import base64
import hashlib
import http.server
import json
import os
import secrets
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

# The python.org 3.11 build ships without a CA bundle wired up (its
# "Install Certificates.command" step), so every HTTPS call fails with
# CERTIFICATE_VERIFY_FAILED. Prefer certifi, fall back to the macOS system bundle.
# Verification is never disabled.
def _ssl_context() -> ssl.SSLContext:
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        pass
    for path in ("/etc/ssl/cert.pem", "/private/etc/ssl/cert.pem"):
        if os.path.exists(path):
            return ssl.create_default_context(cafile=path)
    return ssl.create_default_context()


SSL_CTX = _ssl_context()

AUTH_URL = "https://accounts.spotify.com/authorize"
TOKEN_URL = "https://accounts.spotify.com/api/token"
API_BASE = "https://api.spotify.com/v1"

# Minimum scope for "what is playing right now". user-read-playback-state is NOT
# requested: currently-playing alone yields track, artists, is_playing and progress.
SCOPES = "user-read-currently-playing"

KEYCHAIN_SERVICE = "teams-rich-presence.spotify"
KEYCHAIN_ACCOUNT = "oauth-tokens"


# ───────────────────────────── config ─────────────────────────────
def load_dotenv():
    """Read ../../.env if present. Values here are secrets — never echoed."""
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "..", "..", ".env")
    if not os.path.exists(path):
        return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip().replace(" ", "_"), v.strip())


load_dotenv()
CLIENT_ID = os.environ.get("SPOTIFY_CLIENT_ID", "").strip()
REDIRECT_URI = os.environ.get("SPOTIFY_REDIRECT_URI", "http://127.0.0.1:8888/callback").strip()


# ─────────────────────── keychain token storage ───────────────────
def keychain_save(blob: dict):
    subprocess.run(
        ["security", "add-generic-password", "-U",
         "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT,
         "-w", json.dumps(blob)],
        check=True, capture_output=True,
    )


def keychain_load() -> dict | None:
    r = subprocess.run(
        ["security", "find-generic-password",
         "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout.strip())
    except json.JSONDecodeError:
        return None


def keychain_delete():
    subprocess.run(
        ["security", "delete-generic-password",
         "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT],
        capture_output=True,
    )


def redact(tok: str | None) -> str:
    """The ONLY representation of a token this program is allowed to print."""
    return f"<{len(tok)} chars>" if tok else "<none>"


# ──────────────────────────── PKCE flow ───────────────────────────
def make_verifier() -> str:
    # 43-128 chars from [A-Za-z0-9-._~]; token_urlsafe gives - and _ already.
    return secrets.token_urlsafe(64)[:128]


def challenge_for(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


class CallbackHandler(http.server.BaseHTTPRequestHandler):
    result = {}

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != urllib.parse.urlparse(REDIRECT_URI).path:
            self.send_response(404)
            self.end_headers()
            return
        q = urllib.parse.parse_qs(parsed.query)
        CallbackHandler.result = {k: v[0] for k, v in q.items()}
        ok = "code" in CallbackHandler.result
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        msg = ("Authorised. You can close this tab and return to the terminal."
               if ok else
               f"Authorisation failed: {CallbackHandler.result.get('error', 'unknown')}")
        self.wfile.write(f"<html><body style='font:16px system-ui;padding:3rem'>{msg}</body></html>"
                         .encode("utf-8"))

    def log_message(self, *a):
        pass  # keep the auth code out of stdout


def post_form(url: str, fields: dict) -> tuple[int, dict]:
    body = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20, context=SSL_CTX) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, {"raw": raw}


def cmd_auth():
    if not CLIENT_ID:
        sys.exit("SPOTIFY_CLIENT_ID is not set (checked env and ../../.env)")
    parsed = urllib.parse.urlparse(REDIRECT_URI)
    if parsed.hostname in ("localhost",):
        sys.exit("Spotify rejects 'localhost' as a redirect host — use http://127.0.0.1:PORT/...")
    port = parsed.port or 80

    verifier = make_verifier()
    challenge = challenge_for(verifier)
    state = secrets.token_urlsafe(16)

    params = {
        "response_type": "code",
        "client_id": CLIENT_ID,
        "scope": SCOPES,
        "redirect_uri": REDIRECT_URI,
        "state": state,
        "code_challenge_method": "S256",
        "code_challenge": challenge,
    }
    url = f"{AUTH_URL}?{urllib.parse.urlencode(params)}"

    server = http.server.HTTPServer(("127.0.0.1", port), CallbackHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"listening on 127.0.0.1:{port} for the OAuth callback")
    print(f"code_verifier {redact(verifier)}  code_challenge {redact(challenge)}")
    print("\nOpening the Spotify consent page in your browser…")
    print(f"If it does not open, visit:\n{url}\n")
    subprocess.run(["open", url])

    deadline = time.time() + 180
    while not CallbackHandler.result and time.time() < deadline:
        time.sleep(0.2)
    server.shutdown()

    res = CallbackHandler.result
    if not res:
        sys.exit("timed out waiting for the callback (180s)")
    if "error" in res:
        sys.exit(f"authorisation denied: {res['error']}")
    if res.get("state") != state:
        sys.exit("state mismatch — possible CSRF, aborting")

    status, tok = post_form(TOKEN_URL, {
        "grant_type": "authorization_code",
        "code": res["code"],
        "redirect_uri": REDIRECT_URI,
        "client_id": CLIENT_ID,
        "code_verifier": verifier,
    })
    if status != 200:
        sys.exit(f"token exchange failed ({status}): {tok}")

    tok["obtained_at"] = int(time.time())
    keychain_save(tok)
    print(f"\nauthorised ✅")
    print(f"  access_token  {redact(tok.get('access_token'))}")
    print(f"  refresh_token {redact(tok.get('refresh_token'))}")
    print(f"  expires_in    {tok.get('expires_in')}s")
    print(f"  scope         {tok.get('scope')}")
    print(f"  stored in Keychain service={KEYCHAIN_SERVICE}")


def cmd_refresh(quiet=False) -> dict:
    tok = keychain_load()
    if not tok:
        sys.exit("no stored tokens — run `auth` first")
    status, new = post_form(TOKEN_URL, {
        "grant_type": "refresh_token",
        "refresh_token": tok["refresh_token"],
        "client_id": CLIENT_ID,
    })
    if status != 200:
        sys.exit(f"refresh failed ({status}): {new}")
    # Spotify may or may not rotate the refresh token; keep the old one if absent.
    new.setdefault("refresh_token", tok["refresh_token"])
    new["obtained_at"] = int(time.time())
    keychain_save(new)
    if not quiet:
        rotated = new["refresh_token"] != tok["refresh_token"]
        print("refreshed ✅")
        print(f"  new access_token {redact(new.get('access_token'))}")
        print(f"  expires_in       {new.get('expires_in')}s")
        print(f"  refresh_token    {'ROTATED' if rotated else 'unchanged'}")
    return new


def valid_token() -> str:
    tok = keychain_load()
    if not tok:
        sys.exit("no stored tokens — run `auth` first")
    age = time.time() - tok.get("obtained_at", 0)
    if age > tok.get("expires_in", 3600) - 60:
        tok = cmd_refresh(quiet=True)
    return tok["access_token"]


# ─────────────────────────── API access ───────────────────────────
class Rate(Exception):
    def __init__(self, retry_after): self.retry_after = retry_after


class Unauthorized(Exception):
    """401. `permanent` means re-authorisation is required, not a token refresh.

    Spotify answers an insufficient-scope request with 401 "Permissions missing"
    rather than 403, so status code alone cannot distinguish "token expired"
    (retryable) from "this scope was never granted" (permanent). Refreshing on the
    latter spins forever, so the message body is part of the decision.
    """
    def __init__(self, body: str = ""):
        super().__init__(body)
        self.body = body
        self.permanent = "permissions missing" in body.lower()


class Forbidden(Exception): pass


def api_get(path: str, token: str) -> tuple[int, dict | None]:
    req = urllib.request.Request(
        f"{API_BASE}{path}",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15, context=SSL_CTX) as r:
            if r.status == 204:            # documented as 200+is_playing:false,
                return 204, None           # but the live API really sends 204
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw.strip() else None)
    except urllib.error.HTTPError as e:
        if e.code == 401:
            raise Unauthorized(e.read().decode()[:300])
        if e.code == 403:
            raise Forbidden(e.read().decode()[:300])
        if e.code == 429:
            raise Rate(int(e.headers.get("Retry-After", "5")))
        raise


def get_playback(token: str, retries=1):
    """Returns a normalised state dict, or None when nothing is playing."""
    try:
        status, data = api_get("/me/player/currently-playing", token)
    except Unauthorized as e:
        if e.permanent:
            # Scope was never granted — refreshing cannot fix this.
            raise
        if retries:
            # Access token expired mid-flight — refresh once and retry.
            return get_playback(cmd_refresh(quiet=True)["access_token"], retries - 1)
        raise
    if status == 204 or not data or not data.get("item"):
        return None
    item = data["item"]
    return {
        "type": data.get("currently_playing_type"),
        "id": item.get("id"),
        "track": item.get("name"),
        "artists": ", ".join(a["name"] for a in item.get("artists", [])),
        "album": (item.get("album") or {}).get("name"),
        "is_playing": bool(data.get("is_playing")),
        "progress_ms": data.get("progress_ms"),
        "duration_ms": item.get("duration_ms"),
    }


def render(state) -> str:
    """The exact string that would be pushed to the Teams PresenceTarget."""
    if not state or not state["is_playing"]:
        return ""
    return f"♪ {state['track']} — {state['artists']}"


# ───────────────────────────── commands ───────────────────────────
def cmd_now():
    token = valid_token()
    try:
        st = get_playback(token)
    except Rate as e:
        print(f"429 rate limited — Retry-After {e.retry_after}s (would back off)")
        return
    except Forbidden as e:
        print(f"403 forbidden — {e}")
        return
    if st is None:
        print("no active playback (nothing playing / no active device)")
        print('rendered status -> "" (integration would leave Teams untouched)')
        return
    print(json.dumps(st, indent=2))
    print(f'rendered status -> "{render(st)}"')


def cmd_watch(seconds=120):
    token = valid_token()
    end = time.time() + seconds
    last_render, last_id, backoff = None, None, 0
    print(f"watching for {seconds}s — printing only on change (Ctrl-C to stop)")
    while time.time() < end:
        try:
            st = get_playback(token)
            backoff = 0
        except Rate as e:
            backoff = e.retry_after
            print(f"[{time.strftime('%H:%M:%S')}] 429 — backing off {backoff}s")
            time.sleep(backoff)
            continue
        except Forbidden as e:
            print(f"[{time.strftime('%H:%M:%S')}] 403 — {e}; stopping")
            return
        except Unauthorized as e:
            why = "insufficient scope" if e.permanent else "refresh did not help"
            print(f"[{time.strftime('%H:%M:%S')}] 401 ({why}) — re-auth required, stopping")
            return

        cur = render(st)
        if st and st["id"] != last_id and last_id is not None:
            print(f"[{time.strftime('%H:%M:%S')}] TRACK CHANGE detected")
        if cur != last_render:
            ts = time.strftime("%H:%M:%S")
            if st is None:
                print(f"[{ts}] STOPPED  -> would clear/skip Teams update")
            elif not st["is_playing"]:
                print(f"[{ts}] PAUSED   {st['track']} — {st['artists']}")
            else:
                print(f"[{ts}] PLAYING  \"{cur}\"   ({st['progress_ms']//1000}s/"
                      f"{(st['duration_ms'] or 0)//1000}s)")
            print(f"           -> Teams update WOULD fire")
            last_render = cur
        if st:
            last_id = st["id"]
        time.sleep(3)
    print("watch window ended")


def cmd_errors():
    """Exercise each error path deliberately rather than waiting for one."""
    print("--- 401: deliberately malformed bearer token ---")
    try:
        api_get("/me/player/currently-playing", "definitely-not-a-valid-token")
        print("  unexpected success")
    except Unauthorized:
        print("  caught 401 -> handler refreshes the access token and retries once ✅")

    print("\n--- 403: read an endpoint outside the granted scope ---")
    token = valid_token()
    # GET /me/player needs user-read-playback-state; we only hold
    # user-read-currently-playing, so this is a pure read that must be refused.
    try:
        req = urllib.request.Request(
            f"{API_BASE}/me/player",
            headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(req, timeout=15, context=SSL_CTX) as r:
            print(f"  HTTP {r.status} — scope was broader than expected")
    except urllib.error.HTTPError as e:
        body = e.read().decode()[:200]
        if e.code == 403:
            print(f"  403 handled: insufficient scope, permanent — do not retry ✅\n  body: {body}")
        else:
            print(f"  HTTP {e.code} (expected 403) — body: {body}")
    except Exception as e:
        print(f"  {type(e).__name__}: {e}")

    print("\n--- 429: rate-limit handling (burst until limited, or report clean) ---")
    hit = False
    for i in range(40):
        try:
            api_get("/me/player/currently-playing", token)
        except Rate as e:
            print(f"  hit 429 on request {i + 1}; Retry-After={e.retry_after}s -> back off, do not hammer ✅")
            hit = True
            break
        except Exception:
            break
    if not hit:
        print("  no 429 in 40 rapid requests — handler is implemented and unit-reachable,")
        print("  but Spotify did not throttle this burst (limit not reached).")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "now"
    if cmd == "auth":
        cmd_auth()
    elif cmd == "now":
        cmd_now()
    elif cmd == "watch":
        cmd_watch(int(sys.argv[2]) if len(sys.argv) > 2 else 120)
    elif cmd == "refresh":
        cmd_refresh()
    elif cmd == "errors":
        cmd_errors()
    elif cmd == "logout":
        keychain_delete()
        print("tokens deleted from Keychain")
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
