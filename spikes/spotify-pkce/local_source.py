#!/usr/bin/env python3
"""
local_source.py — Phase C alternative: read Spotify state from the local desktop app
via its AppleScript dictionary, with no OAuth, no network, and no rate limit.

Discovered in Phase A: /Applications/Spotify*.app ships a full sdef exposing
  application: current track, player state (playing|paused|stopped), player position
  track:       name, artist, album, album artist, duration, id, spotify url,
               artwork url, popularity, track number, disc number, starred

This is a second PresenceSource implementation of the same contract as the Web API
source, and it is strictly better for this product's purpose:

  * no OAuth, no client ID, no redirect URI, no dashboard registration
  * no token storage and therefore no token to leak
  * no 401/403/429 and no quota, so it can be polled as fast as you like
  * works offline

Measured on this machine: ~180 ms per read via `osascript` (process spawn dominates)
vs ~230 ms for the Web API call. A production build using NSAppleScript/ScriptingBridge
in-process avoids the spawn and should be far cheaper, but that is NOT measured here —
do not assume it without benchmarking.

Its limits, which are why the Web API source is still worth keeping:
  * only sees the *local desktop app* — playback on a phone or web player is invisible
  * returns only the PRIMARY artist. Measured: this source reports "Dom Dolla" where
    the Web API reports "Dom Dolla, Go Freek" for the same track id.
  * requires the Automation (Apple Events) TCC grant for the controlling app
  * Spotify could drop the sdef in a future release

Usage:
    ./local_source.py now
    ./local_source.py watch [seconds]
    ./local_source.py compare      read both this and the Web API, side by side
"""

import json
import subprocess
import sys
import time

BUNDLE = "com.spotify.client"

# One round trip returns everything; querying properties individually is ~6x slower.
# The `is running` test is deliberately OUTSIDE the tell block — addressing a
# non-running app inside `tell` would launch Spotify as a side effect of reading it.
# `st` and `t` are reserved tokens in AppleScript and fail to parse here
# ("Expected expression but found st"); pstate/trk are safe.
# NOTE: `duration` is milliseconds despite the sdef documenting it as seconds,
# while `player position` really is seconds.
SCRIPT = f'''
if application id "{BUNDLE}" is not running then return "NOTRUNNING"
tell application id "{BUNDLE}"
    set pstate to player state as text
    if pstate is "stopped" then return "STOPPED"
    set trk to current track
    set d to tab
    return pstate & d & (name of trk) & d & (artist of trk) & d & (album of trk) & d & (id of trk) & d & (duration of trk) & d & (player position as integer)
end tell
'''


def read_state():
    """Returns the same normalised dict shape as the Web API source, or None."""
    r = subprocess.run(["osascript", "-e", SCRIPT], capture_output=True, text=True, timeout=10)
    if r.returncode != 0:
        err = r.stderr.strip()
        if "-1743" in err:
            raise PermissionError(
                "Automation (Apple Events) permission denied for Spotify. Grant it under "
                "System Settings > Privacy & Security > Automation."
            )
        raise RuntimeError(err or "osascript failed")
    out = r.stdout.strip()
    if out in ("NOTRUNNING", "STOPPED", ""):
        return None
    parts = out.split("\t")
    if len(parts) < 7:
        return None
    state, name, artist, album, tid, dur, pos = parts[:7]
    return {
        "type": "track",
        "id": tid.rsplit(":", 1)[-1],
        "track": name,
        "artists": artist,
        "album": album,
        "is_playing": state == "playing",
        "progress_ms": int(float(pos)) * 1000,
        "duration_ms": int(float(dur)),
    }


def render(st):
    if not st or not st["is_playing"]:
        return ""
    return f"♪ {st['track']} — {st['artists']}"


def cmd_now():
    t0 = time.perf_counter()
    st = read_state()
    ms = (time.perf_counter() - t0) * 1000
    if st is None:
        print("no local playback (Spotify not running, or stopped)")
        print('rendered status -> ""')
    else:
        print(json.dumps(st, indent=2))
        print(f'rendered status -> "{render(st)}"')
    print(f"read latency: {ms:.1f} ms")


def cmd_watch(seconds=60):
    end = time.time() + seconds
    last, last_id = None, None
    print(f"watching local Spotify for {seconds}s — printing only on change")
    while time.time() < end:
        st = read_state()
        cur = render(st)
        if st and last_id is not None and st["id"] != last_id:
            print(f"[{time.strftime('%H:%M:%S')}] TRACK CHANGE detected")
        if cur != last:
            ts = time.strftime("%H:%M:%S")
            if st is None:
                print(f"[{ts}] STOPPED")
            elif not st["is_playing"]:
                print(f"[{ts}] PAUSED   {st['track']} — {st['artists']}")
            else:
                print(f"[{ts}] PLAYING  \"{cur}\"")
            last = cur
        if st:
            last_id = st["id"]
        time.sleep(1)
    print("watch window ended")


def cmd_compare():
    """Both sources, same moment — do they agree, and how fast is each?"""
    sys.path.insert(0, ".")
    import spotify_spike as web

    t0 = time.perf_counter()
    local = read_state()
    local_ms = (time.perf_counter() - t0) * 1000

    t0 = time.perf_counter()
    try:
        remote = web.get_playback(web.valid_token())
        remote_ms = (time.perf_counter() - t0) * 1000
        remote_err = None
    except Exception as e:
        remote, remote_ms, remote_err = None, (time.perf_counter() - t0) * 1000, repr(e)

    print(f"{'':12} {'AppleScript (local)':40} {'Web API (network)':40}")
    print(f"{'-' * 92}")
    for key in ("track", "artists", "album", "is_playing", "id"):
        lv = local.get(key) if local else None
        rv = remote.get(key) if remote else None
        mark = "" if lv == rv else "   <-- differs"
        print(f"{key:12} {str(lv):40} {str(rv):40}{mark}")
    print(f"{'latency':12} {local_ms:>7.1f} ms{'':30} {remote_ms:>7.1f} ms")
    if remote_err:
        print(f"web api error: {remote_err}")
    print(f"\nrendered (local)  -> \"{render(local)}\"")
    print(f"rendered (web)    -> \"{web.render(remote)}\"")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "now"
    try:
        if cmd == "now":
            cmd_now()
        elif cmd == "watch":
            cmd_watch(int(sys.argv[2]) if len(sys.argv) > 2 else 60)
        elif cmd == "compare":
            cmd_compare()
        else:
            print(__doc__)
    except PermissionError as e:
        sys.exit(f"PERMISSION: {e}")
