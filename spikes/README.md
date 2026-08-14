# Spikes — how to reproduce every experiment

Disposable investigation code for the Teams Rich Presence feasibility study.
Findings and conclusions live in [`../docs/FEASIBILITY.md`](../docs/FEASIBILITY.md).

**This is throwaway code.** It exists to produce evidence, not to be extended into the
product. Read it for the selectors and the failure modes, then write the real thing.

---

## Prerequisites

* macOS 14+ (tested on 15.3.1, arm64)
* Xcode command line tools — `swiftc` (tested with Swift 6.1.2)
* Python 3.9+ for the Spotify spikes (stdlib only, no `pip install`)
* Microsoft Teams installed and signed in
* Spotify desktop app installed and signed in

### Permissions you must grant first

Whichever application runs these commands — Terminal, iTerm, VS Code — needs:

1. **Accessibility** — System Settings ▸ Privacy & Security ▸ Accessibility.
   Without it every AX call returns `-25211` (`APIDisabled`).
   Verify with `teams-ax/probe` (below): it must print `AXIsProcessTrusted() = true`.
2. **Automation** — System Settings ▸ Privacy & Security ▸ Automation, allowing control of
   **Microsoft Teams**, **Spotify** and **System Events**. macOS prompts on first use.

> These experiments **change your real Teams status message** and, in a few places, quit and
> relaunch Teams and Spotify. Record your current status first:
> `cd teams-ax && ./set_status --get`

---

## Teams accessibility spikes (`teams-ax/`)

Build everything:

```sh
cd teams-ax
for f in probe dump teamsctl settext set_status enable_a11y unlock_a11y \
         nodecount trigger_a11y observer_trigger enable_webview_a11y; do
  swiftc -O "$f.swift" -o "$f"
done
chmod +x restart_probe.sh
```

### Start here, in this order

**1. Confirm the Accessibility API is usable** — experiment B0

```sh
./probe
```
Expect `AXIsProcessTrusted() = true` and one Teams window.

**2. Make the Teams web UI visible to the Accessibility API** — experiment B10 ⚠️ **required**

```sh
./trigger_a11y
```
On a freshly started Teams the app tree has only ~250 nodes and **no web content at all**.
This is the reproducible enabler: node count goes ~250 → ~1250 and `webArea=YES` appears.
See FEASIBILITY.md §2.6 — **nothing else below works until this succeeds.**

**3. Explore the tree** — experiment B1

```sh
./dump 30 | grep -v '@/1/'      # whole tree, minus the native menu bar
./dump 8                        # shallow overview
```

**4. Find elements semantically** — experiment B3

```sh
./teamsctl winfo
./teamsctl find role=AXButton 'desc~=Your profile'
./teamsctl find role=AXTextArea 'desc~=mention someone'
./teamsctl attrs '@role=AXTextArea,desc~=mention someone'   # every attribute + settable flags
./teamsctl tree /0 6                                        # subtree by index path
```

Predicates: `role=` `sub=` `desc=` `title=` `value=` `placeholder=` `id=`.
Use `~=` for case-insensitive contains, `=` for exact.
`@pred1,pred2` addresses the first match; a bare `/0/3/1` addresses by child index.

Other subcommands: `press <spec> [action]`, `setval <spec> <text>`,
`setattr <spec> <AXAttr> <value>`, `activate <spec> [keycode]`, `focused`.

**5. Reproduce the text-write comparison** — experiment B4

Open the status editor first:
```sh
./teamsctl activate '@role=AXButton,desc~=Your profile' 36
./teamsctl activate '@role=AXButton,desc~=Edit status message' 36
```
Then:
```sh
./settext all '♪ Test'          # tries AXValue, AXSelectedText, AXReplaceRange, key events
./settext keys '♪ Test'         # the only one that works
./settext keysbulk '♪ Test'     # whole string in one event — inserts nothing
./settext paste '♪ Test'        # pasteboard + ⌘V — does nothing
./settext menupaste '♪ Test'    # Edit▸Paste via AXPress — reports success, does nothing
```
Watch the `TEXT CHANGED ✅` / `no effect ❌` column. Only `keys` succeeds.
Try `./settext keys '🎵 Test'` to see the emoji get dropped.

**6. The end-to-end status change** — experiment B5 ⭐ **the main result**

```sh
./set_status --get                                  # read, change nothing
./set_status '♪ Dreams — Fleetwood Mac'
./set_status '♪ Rhiannon — Fleetwood Mac' --clear-after '1 hour'
./set_status 'plain text status' --clear-after 'Never'
./set_status 'x' --no-show-when-messaged
./set_status --clear                                # delete the status message
```

Every run prints the frontmost app before and after and asserts
`focus PRESERVED ✅`. Clear-after options: `Never` `Today` `1 hour` `4 hours` `This week` `Custom`.

Exit codes: `0` ok · `2` flyout unreachable · `3` compose box not found ·
`4` Done failed · `5` committed value ≠ requested · `10` Teams not running.

### Reproducing the window-state matrix (FEASIBILITY.md §2.5)

```sh
# background — the primary case
osascript -e 'tell application "Visual Studio Code" to activate'; sleep 1
./set_status '♪ Backgrounded'          # works, focus preserved

# minimised — fails, then recovers
./teamsctl setattr /0 AXMinimized true;  sleep 2
./set_status '♪ Minimised'             # exit 2
./teamsctl setattr /0 AXMinimized false; sleep 3
./set_status '♪ Restored'              # works, focus still preserved

# no main window — fails, then recovers
./teamsctl press '@role=AXButton,sub=AXCloseButton'; sleep 2
./teamsctl winfo                       # AXWindows=0
./set_status '♪ No window'             # exit 2
osascript -e 'tell application id "com.microsoft.teams2" to reopen'; sleep 3
./set_status '♪ Reopened'              # works, focus preserved

# restart
osascript -e 'tell application id "com.microsoft.teams2" to quit'
open -a "Microsoft Teams"; sleep 60
./trigger_a11y                         # REQUIRED after every restart
./set_status '♪ After restart'
```

### The accessibility-enabler investigation (§2.6)

These are the negative results. Each needs a **freshly restarted Teams** to be meaningful —
once the tree is up it stays up, so re-running them on a live tree proves nothing.

```sh
./enable_a11y                              # B2: AXManualAccessibility/AXEnhancedUserInterface rejected
./enable_webview_a11y --mode manual        # B8: setting the attribute on helper pids alone — fails
./enable_webview_a11y --mode read          # B8: deep-reading helper pids alone — fails
./enable_webview_a11y --mode both          # B8: both together — fails
./observer_trigger 90                      # B9: AXObserver alone, 90s — fails
./observer_trigger 90 --touch              # B9: observer + helper contact — fails
./trigger_a11y                             # B10: the full sequence — WORKS (2/2)
./restart_probe.sh                         # B7: quits Teams, proves waiting alone never works (~7 min)
```

`./nodecount` prints the current Teams AX node count; `./nodecount --touch-webview` contacts the
helper processes. Useful for watching the transition (~250 → ~1250).

---

## Spotify spikes (`spotify-pkce/`)

No build step. Reads `SPOTIFY_CLIENT_ID` from `../../.env`.

**Redirect URI `http://127.0.0.1:8888/callback` must be registered** in your app at
developer.spotify.com ▸ your app ▸ Settings ▸ Redirect URIs. Spotify rejects `localhost`.

```sh
cd spotify-pkce

./spotify_spike.py auth        # C1: PKCE flow — opens a browser tab, approve once
./spotify_spike.py now         # current track + the status string it would render
./spotify_spike.py watch 120   # poll 120s, print only on change
./spotify_spike.py refresh     # force a refresh-token exchange
./spotify_spike.py errors      # exercise the 401 / scope / 429 paths
./spotify_spike.py logout      # delete tokens from the Keychain
```

Tokens go to the macOS Keychain under service `teams-rich-presence.spotify`.
Inspect with `security find-generic-password -s teams-rich-presence.spotify -w`.
**No token is ever printed** — only its character count.

### Reproducing the state-change detection

Run the watcher, then drive Spotify from another shell:

```sh
./spotify_spike.py watch 75 &
sleep 12; osascript -e 'tell application id "com.spotify.client" to next track'
sleep 18; osascript -e 'tell application id "com.spotify.client" to pause'
sleep 16; osascript -e 'tell application id "com.spotify.client" to play'
sleep 14; osascript -e 'tell application id "com.spotify.client" to next track'
```

### Reproducing "no active playback" (HTTP 204)

```sh
osascript -e 'tell application id "com.spotify.client" to quit'; sleep 10
./spotify_spike.py now       # -> "no active playback", renders ""
open -b com.spotify.client   # note: `open -a Spotify` fails — the bundle is named "Spotify (old) (old).app"
```

### The local AppleScript source — C2

```sh
./local_source.py now        # no OAuth, no network
./local_source.py watch 60
./local_source.py compare    # both sources side by side, same instant
```

`compare` shows the measured divergence: the local source reports only the **primary** artist
where the Web API reports all of them.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Every AX call returns `-25211` | No Accessibility permission for the host app |
| `find` returns 0 matches for `Your profile` | Renderer a11y tree is off — run `./trigger_a11y` |
| `AXPress` succeeds but nothing happens | Expected on the force-enabled tree; use `teamsctl activate` (focus + Return) |
| `set_status` exits 2 | Teams minimised, has no window, or the tree is off |
| `CERTIFICATE_VERIFY_FAILED` in Python | python.org build without a CA bundle — the script already falls back to `/etc/ssl/cert.pem` |
| `Unable to find application named 'Spotify'` | Use `open -b com.spotify.client` |
| Emoji missing from the status | Expected — astral-plane characters are dropped, `🎵` is rewritten to `♪` |

## File map

| File | Experiment | Purpose |
|---|---|---|
| `teams-ax/probe.swift` | B0 | Is the AX API usable at all |
| `teams-ax/dump.swift` | B1 | Walk and print the AX tree |
| `teams-ax/enable_a11y.swift` | B2 | Reject `AXManualAccessibility` / `AXEnhancedUserInterface` |
| `teams-ax/teamsctl.swift` | B3 | Semantic find / press / activate / attrs |
| `teams-ax/settext.swift` | B4 | Six text-write strategies compared |
| `teams-ax/set_status.swift` | B5 | **End-to-end status change** |
| `teams-ax/unlock_a11y.swift` | B6 | First sighting of the tree materialising |
| `teams-ax/restart_probe.sh`, `nodecount.swift` | B7 | Waiting alone never works |
| `teams-ax/enable_webview_a11y.swift` | B8 | Isolate manual / read / both |
| `teams-ax/observer_trigger.swift` | B9 | `AXObserver` alone is insufficient |
| `teams-ax/trigger_a11y.swift` | B10 | **The reproducible enabler** |
| `spotify-pkce/spotify_spike.py` | C1 | PKCE + Web API |
| `spotify-pkce/local_source.py` | C2 | AppleScript source + comparison |
