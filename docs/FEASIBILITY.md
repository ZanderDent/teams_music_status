# Teams Rich Presence — Feasibility Report

**Phase:** investigation only. No production application was built.
**Date of evidence:** 14 August 2026
**Machine:** the MacBook Pro described in §1. Every claim below was observed on that machine unless explicitly marked otherwise.

---

## 0. Verdict up front

**GO**, with one substantial engineering caveat and one policy question for you.

Both halves of the definition of success were demonstrated end to end on this machine:

* The program read the actual currently-playing Spotify track from your account
  (`Define — Dom Dolla, Go Freek`, `is_playing: true`) via OAuth 2.0 Authorization Code + PKCE.
* The program changed the actual installed Microsoft Teams custom status message, repeatedly,
  while Teams was in the background, without ever stealing focus from the foreground application.
  Verified by reading the value back out of Teams' own UI after each commit.

The caveat is §2.6: **Teams' WebView2 renderer does not publish its accessibility tree by default**,
and the trigger that makes it do so was found empirically and is not fully understood. This is the
single largest risk in the product and is the first thing Phase 1 must harden.

---

## 1. Environment discovered

| | |
|---|---|
| macOS | 15.3.1 (build 24D70) |
| Architecture | arm64 — Apple M1 Pro, MacBookPro18,1, 10 cores, 32 GB |
| Microsoft Teams | `/Applications/Microsoft Teams.app`, bundle id `com.microsoft.teams2`, version **26183.1901.4874.5228**, `LSMinimumSystemVersion 14.0` |
| Teams UI stack | **Microsoft Edge WebView2**, not Electron — `Frameworks/MSWebView2.framework`, renderer is `Microsoft Edge Framework.framework/Versions/149.0.4022.96`, helper process `Microsoft Teams WebView` launched with `--embedded-browser-webview=1` |
| Teams sandboxing | Yes — data under `~/Library/Containers/com.microsoft.teams2/` |
| Spotify | `/Applications/Spotify (old) (old).app`, bundle id `com.spotify.client`, version 1.2.96.518 |
| Swift | 6.1.2 (swiftlang-6.1.2.1.2), target arm64-apple-macosx15.0 |
| Xcode | 16.4 (16F6) |
| Rust | rustc 1.95.0 / cargo 1.95.0 |
| Node | v22.22.1, npm 10.9.4 |
| Python | 3.11.8 (python.org build) |
| Homebrew | 6.0.12 |

**Accessibility permission.** The spike ran as a child of Visual Studio Code
(`com.microsoft.VSCode`), which already holds the Accessibility grant, so
`AXIsProcessTrusted()` returned `true` with no prompt. The production app will need its own
grant — see §9.

### 1.1 Answers to the Phase A questions

**5. How Teams exposes its interface through Accessibility.** Once the renderer tree is
published (§2.6), extremely well. The Teams web UI is fully instrumented: elements carry
`AXRole`, `AXSubrole`, `AXDescription`, `AXTitle`, `AXPlaceholderValue`, and — critically —
`AXDOMIdentifier`, which is the DOM `id` attribute. This is a first-class semantic surface,
not a coordinate grid. Roughly 1250 nodes in the app tree with the UI loaded.

**6. Does AppleScript provide anything useful?** For Teams, almost nothing:
`sdef /Applications/Microsoft\ Teams.app` fails with error `-192` (no scripting definition),
and `Info.plist` declares neither `NSAppleScriptEnabled` nor `OSAScriptingDefinition`. Teams
cannot be scripted directly.

One thing *is* useful, and it turned out to matter: the Standard Suite `reopen` verb is
handled by AppKit even without a dictionary, and
`osascript -e 'tell application id "com.microsoft.teams2" to reopen'` reliably restores a
closed main window **without stealing focus** (§2.5).

For **Spotify**, AppleScript is excellent — a full `sdef` exposing `current track`
(name, artist, album, album artist, id, duration, artwork url, spotify url, popularity,
starred), `player state` (playing/paused/stopped) and `player position`. This is a complete
second implementation of the Spotify source (§3.4).

**7. Does the Electron/WebView architecture expose a better local automation surface?**
No. Teams is not Electron, so there is no Node integration and no Electron IPC. It is WebView2,
and:
* no process listens on any TCP port (`lsof -nP -iTCP -sTCP:LISTEN` shows nothing for Teams),
  so there is no Chrome DevTools Protocol endpoint to attach to;
* enabling one would require relaunching Teams with `--remote-debugging-port`, which the
  production app cannot do to a user's already-running, corporate-managed Teams.

The Accessibility API is the correct and only viable local surface.

**8. Can elements be addressed semantically rather than by coordinates?** **Yes, completely.**
No screen coordinates are used anywhere in the working spike. See the selector table in §7.

---

## 2. Teams automation findings

### 2.1 The workflow that works

```
profile button  (AXButton, AXDescription starts "Your profile")
  → "Edit status message" (AXButton) | "Set status message" (AXMenuItem, when no status is set)
    → compose box (AXDOMIdentifier = "status-note-compose")
      → ⌘A, Delete, then per-character unicode key events
      → optional: "Clear status message after" (AXPopUpButton) → option
      → "Done" (AXButton, AXTitle = "Done")
```

Committed status is then verified by re-reading the `AXTextField` whose `AXDescription`
starts `"Your current status message"`.

### 2.2 Writing text: five approaches failed, one works

The compose box is **CKEditor 5** — `AXDOMClassList` contains `ck`, `ck-content`,
`ck-editor__editable`. CKEditor maintains its own document model, so poking the DOM does
nothing even when the Accessibility API reports success.

| Approach | `AXError` | Actually changed the text? |
|---|---|---|
| Set `AXValue` | `.success` | **No** |
| Set `AXSelectedTextRange` then `AXSelectedText` | `.success` | **No** |
| `AXReplaceRangeWithText` parameterized attribute | `.success` | **No** |
| Pasteboard + ⌘V via `CGEventPostToPid` | n/a | **No** |
| Pasteboard + `AXPress` on the native Edit ▸ Paste menu item | `.success` (both) | **No** (while backgrounded) |
| **`AXFocused = true`, then ⌘A, Delete, then one unicode key event per character, all via `CGEventPostToPid`** | n/a | **Yes** ✅ |

> **Critical lesson: `AXError.success` is not evidence.** Chromium returns `.success` from
> `AXUIElementSetAttributeValue` and `AXUIElementPerformAction` for operations it then silently
> drops. Every mutation in this codebase is verified by reading state back. Any production code
> that trusts the return value will appear to work and will not.

Two details that cost real debugging time and must not be lost:

* **Modifier flags leak.** `CGEventSource(stateID: .privateState)` latches the Command
  modifier from the ⌘A. Every subsequent event must set `e.flags = []` explicitly or Chromium
  reads the keystrokes as shortcuts and inserts nothing.
* **Astral-plane emoji are dropped.** `🎵` (U+1F3B5, a UTF-16 surrogate pair) never arrives,
  whether sent per-character or as one bulk unicode string. BMP characters are fine, including
  `♪` U+266A, `♫` U+266B and `—` U+2014. The spike substitutes `🎵 → ♪` and reports the
  rewrite. **The example status in the brief, `🎵 Dreams — Fleetwood Mac`, therefore renders as
  `♪ Dreams — Fleetwood Mac`.** This is a real product decision for you, not a bug I can fix
  from here.

### 2.3 Activating controls: `AXPress` is unreliable

After a Teams restart, `AXPress` returned `.success` on the profile button, the Edit button,
the Done button and the clear-duration popup while doing **nothing at all** — node counts before
and after were identical and no flyout opened.

The reliable, still coordinate-free primitive is:

```
AXUIElementSetAttributeValue(element, kAXFocusedAttribute, true)   // semantic focus
CGEvent(virtualKey: 36 /* Return */).postToPid(teamsPid)           // real key event
```

with **Space (49) for `AXCheckBox`** and Return for buttons. The spike's `activate()` helper
tries `AXPress` first, verifies the expected effect, and falls back to focus + Return/Space,
verifying again. In the post-restart session every single control needed the fallback.

### 2.4 Status message constraints

* **Length limit: 280 characters.** Exposed live as an `AXStaticText` reading `"N / 280"`.
* **Clear duration** is settable programmatically. Options observed on this Teams build:
  `Never`, `Today`, `1 hour`, `4 hours`, `This week`, `Custom`. Setting `4 hours` was verified —
  the status readout then reads `"♪ Clear-after retest\nDisplay until 12:03 PM"`.
* With a clear duration set, the readout has **two lines**; only the first is the message.
* **`Never` really is indefinite** — there is no forced expiry. A status set to `Never` persisted
  across a full Teams quit/relaunch (observed: `♪ Post-restart verification` survived restart #3).
* The **"Show when people message me"** checkbox (`AXDOMIdentifier = checkbox-rd2`) is present
  and was toggled successfully in both directions in a healthy tree — see §2.6 for why it became
  unreadable later.

### 2.5 Behaviour by Teams window state

| Teams state | Read status | Change status | Focus stolen | Notes |
|---|---|---|---|---|
| Foregrounded | ✅ | ✅ | n/a | |
| **Backgrounded** | ✅ | ✅ | **No** ✅ | The primary target case. Verified repeatedly with the frontmost app staying `Code` / `Spotify` throughout. |
| **Minimised** | ✅ tree readable (1019 nodes) | ❌ | — | `AXPress`/flyout does nothing while the window is genie'd to the Dock. |
| Minimised + mitigation | ✅ | ✅ | **No** ✅ | Set `AXMinimized = false`, wait ~2 s, proceed. Restoring the window does **not** activate the app. |
| **No open main window** | ❌ (`AXWindows = 0`, no tree at all) | ❌ | — | Closing the last window removes the entire AX surface. |
| No window + mitigation | ✅ | ✅ | **No** ✅ | `osascript -e 'tell application id "com.microsoft.teams2" to reopen'`. Went `AXWindows 0 → 1` with the frontmost app unchanged. |
| **Restarted** | ✅ | ✅ | **No** ✅ | **But only after the §2.6 enabler runs.** Status set before the restart survived it. |
| Not running | — | — | — | Fails cleanly, exit code 10. |

**Focus behaviour is the headline result: in every successful path, the user's frontmost
application never changed.** Key events are delivered with `CGEventPostToPid` to the Teams
process specifically rather than posted to the global event tap, and `AXFocused` moves the
caret inside Teams without activating it.

### 2.6 ⚠️ The big problem: the WebView2 accessibility tree is off by default

**On a freshly launched Teams, the entire web UI is invisible to the Accessibility API.**
The app tree contains ~250 nodes — the native menu bar and window chrome only. The window
subtree bottoms out in bare `AXGroup`s about seven levels down; there is no `AXWebArea` and
no profile button. Teams is fully loaded and usable by a human at this point.

Chromium gates its renderer accessibility tree on assistive-technology detection. Things that
were tested on a freshly restarted Teams and **did not work**:

| Attempt | Result |
|---|---|
| Simply waiting | No tree after **7 minutes** of polling |
| `AXManualAccessibility = true` on the main app element | `attributeUnsupported` (−25205) |
| `AXEnhancedUserInterface = true` on the main app element | `notImplemented` (−25208) |
| `AXManualAccessibility` on each `Microsoft Teams WebView` helper pid, alone | `attributeUnsupported` / `cannotComplete`; no tree after 15 s |
| Deep AX reads of the helper pids' trees, alone | No tree after 15 s |
| Both of the above together | No tree after 20 s |
| `AXObserver` registration (5 notifications) + live run loop, alone | No tree after **90 s** |
| `AXObserver` + helper-pid contact, in that order | No tree after 90 s |
| System Events UI-scripting poke (`tell process "Microsoft Teams" to count windows`) | No effect |

What **does** work, reproducibly (2 of 2 attempts on separate Teams instances), is the exact
sequence in `spikes/teams-ax/trigger_a11y.swift`: register an `AXObserver` for **seven**
notification types (including `kAXApplicationActivatedNotification` and
`kAXCreatedNotification`, which the failing 5-notification variant omitted), pump the run loop
for ~10 s, and *then* contact the WebView helper processes. Node count goes 249 → 1253 and the
`AXWebArea` appears within ~2 seconds.

**I could not isolate the minimal sufficient subset.** The difference between the working and
failing variants is confounded between (a) the two extra notification types, (b) the ~10 s of
run-loop pumping before helper contact, and (c) the exact helper-read depth. This is the
highest-priority open question for Phase 1.

### 2.7 ⚠️ The force-enabled tree is degraded

This matters as much as §2.6 and I want to be blunt about it: the tree obtained via the
enabler is **not equivalent** to the tree that was present at the start of this session on a
long-running Teams instance.

| | Organically-enabled tree | Force-enabled tree |
|---|---|---|
| `AXPress` on buttons | Worked | Returns `.success`, does nothing |
| `AXCheckBox` `AXValue` | `"0"` / `"1"` | **empty string** — state unreadable |
| Text insertion | Worked | Works |
| Element discovery | Worked | Works |

Because the checkbox state became unreadable, the spike **refuses to toggle it** rather than
blind-toggling and risking turning the user's setting off. You asked me to make sure
"Show when people message me" gets checked — it is implemented and it demonstrably worked in
both directions on the healthy tree, but on the degraded tree the honest behaviour is to skip
it and say so, which is what the code now does. Resolving §2.6 properly should also resolve this.

---

## 3. Spotify API findings

### 3.1 Auth

* **OAuth 2.0 Authorization Code + PKCE, no client secret.** `S256`, 86-character verifier,
  43-character challenge, `state` checked on callback.
* **Redirect URI: `http://127.0.0.1:8888/callback`** — already registered on your app.
  Spotify removed support for `localhost` as a redirect host, enforced **27 November 2025**;
  loopback IP literals (`127.0.0.1`, `[::1]`) over HTTP remain allowed.
  ([policy](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri),
  [migration notice](https://developer.spotify.com/blog/2025-10-14-reminder-oauth-migration-27-nov-2025))
* **Scope requested: `user-read-currently-playing` only.** `user-read-playback-state` proved
  unnecessary — track, artists, `is_playing` and `progress_ms` all come from the
  currently-playing endpoint.
* **Tokens are stored in the macOS Keychain** (`security add-generic-password`, service
  `teams-rich-presence.spotify`). No token is ever written to disk in the repo or printed;
  the only representation logged is its character count.

### 3.2 Results against the required list

| # | Requirement | Result |
|---|---|---|
| 1 | Authenticate | ✅ access token (234 chars), refresh token (131 chars), `expires_in 3600` |
| 2 | Retrieve current track | ✅ `Define`, `Feel Good`, `Take me back to 97'`, … |
| 3 | Retrieve artist | ✅ `Dom Dolla, Go Freek` (all artists joined) |
| 4 | Playing vs paused | ✅ observed both, transitions logged |
| 5 | Detect track changes | ✅ two track changes detected by track `id` comparison |
| 6 | Refresh authentication | ✅ new access token issued; **refresh token was not rotated** |
| 7 | No active playback | ✅ Spotify quit → HTTP **204** → renders `""` → integration leaves Teams untouched |
| 8a | Handle 401 | ✅ refresh-and-retry-once path exercised |
| 8b | Handle 403 | ⚠️ **see §3.3 — Spotify does not send 403 here** |
| 8c | Handle 429 | ⚠️ implemented, **not observed** — see §3.3 |

Sample of the change-detection run:

```
[08:04:50] PAUSED   Was I Loved? — Joss Dean
[08:05:10] TRACK CHANGE detected
[08:05:10] PLAYING  "♪ Take me back to 97' — Cody Wong"   (1s/262s)
[08:05:16] PAUSED   Take me back to 97' — Cody Wong
[08:05:45] PLAYING  "♪ Take me back to 97' — Cody Wong"   (10s/262s)
[08:05:58] TRACK CHANGE detected
[08:05:58] PLAYING  "♪ Define — Dom Dolla, Go Freek"   (1s/232s)
```

### 3.3 Two honest caveats on error handling

**Insufficient scope returns 401, not 403.** Requesting `GET /me/player` (which needs
`user-read-playback-state`, not granted) returned:

```
HTTP 401  {"error": {"status": 401, "message": "Permissions missing"}}
```

This is important: a naive `401 → refresh token → retry` loop **spins forever** on a scope
problem, because refreshing cannot fix it. The spike distinguishes them by inspecting the
message body and marks `Permissions missing` as permanent. I did not observe a genuine 403
from this API at all.

**429 was not reproduced.** 200 sequential requests at 5.2 req/s (≈312 req/min) did not
trigger rate limiting. The handler (read `Retry-After`, back off, never hammer) is implemented
and reachable, but **it has not been exercised against a real 429 on this machine**, and I
chose not to escalate further — a harder burst risks an extended app-level limit on your client
ID for little extra evidence. For context, the production polling rate is ~0.3 req/s, three
orders of magnitude below what already failed to trip it.

### 3.4 A second, simpler Spotify source exists

Spotify's desktop app ships a full AppleScript dictionary. `spikes/spotify-pkce/local_source.py`
implements the same normalised state shape with **no OAuth, no network, no tokens, no quota**.
Verified side by side against the Web API at the same instant — same track, same album, same
track id, same `is_playing`.

Two measured differences worth knowing:

* **Artists.** The local source returns only the **primary** artist: `Dom Dolla` where the Web
  API returns `Dom Dolla, Go Freek`.
* **Latency.** ~178 ms local (via `osascript`, dominated by process spawn) vs ~232 ms for the
  Web API. An in-process `NSAppleScript` implementation should be far cheaper, but **I did not
  measure that** — do not assume it.

Its real limitation is scope: it only sees the local desktop app. Playback from your phone or
the web player is invisible to it, whereas the Web API sees your account wherever it is playing.

Recommendation: ship **both** behind `PresenceSource`, defaulting to the Web API for
correctness, with the local source as a zero-friction fallback when the user declines OAuth or
is offline.

---

## 4. Exact experiments performed

All code is under `spikes/`. See `spikes/README.md` for build and run instructions.

| ID | File | What it established |
|---|---|---|
| A1 | shell | macOS/arch/toolchain inventory |
| A2 | shell | Teams is WebView2, not Electron; no scripting dictionary; no CDP port |
| A3 | shell | Spotify `sdef` is rich |
| B0 | `teams-ax/probe.swift` | `AXIsProcessTrusted()`, Teams AX app element reachable |
| B1 | `teams-ax/dump.swift` | Full AX tree walk; found the semantic web tree |
| B2 | `teams-ax/enable_a11y.swift` | `AXManualAccessibility` / `AXEnhancedUserInterface` both rejected |
| B3 | `teams-ax/teamsctl.swift` | Reusable semantic finder/presser/attribute inspector |
| B4 | `teams-ax/settext.swift` | Six text-write strategies compared; only per-char key events work |
| B5 | `teams-ax/set_status.swift` | **End-to-end status change**, all states, focus measurement |
| B6 | `teams-ax/unlock_a11y.swift` | First observation of the tree materialising |
| B7 | `teams-ax/restart_probe.sh` + `nodecount.swift` | 7-minute proof that waiting alone never works |
| B8 | `teams-ax/enable_webview_a11y.swift` | Isolated `manual` / `read` / `both` — all insufficient |
| B9 | `teams-ax/observer_trigger.swift` | `AXObserver` alone insufficient (90 s) |
| B10 | `teams-ax/trigger_a11y.swift` | **The reproducible enabler** (2/2) |
| C1 | `spotify-pkce/spotify_spike.py` | PKCE auth, now, watch, refresh, errors, logout |
| C2 | `spotify-pkce/local_source.py` | AppleScript source + side-by-side comparison |

Teams was quit and relaunched **three times** during this investigation. Your original status
message, `Listening to: House`, was recorded at the start and has been restored.

---

## 5. What succeeded

* Reading the real currently-playing track from your real Spotify account via PKCE.
* Changing the real Teams custom status message, repeatedly, verified by readback.
* Doing so with Teams **backgrounded** and **without stealing focus**, every time.
* Purely semantic addressing — **zero screen coordinates** in the working code.
* Setting the clear-duration (`Never` ↔ `1 hour` ↔ `4 hours`) programmatically.
* Reading the user's existing status, and restoring it afterwards — the save/restore
  requirement is proven, not theoretical.
* Recovering from: minimised window, closed window, and full application restart.
* Clean failure when Teams is not running.
* Spotify: refresh, track-change detection, pause detection, no-playback (204), 401 handling.
* Keychain-backed token storage with no token ever logged.

## 6. What failed

* **Astral-plane emoji cannot be typed into Teams** (§2.2). `🎵` becomes `♪`.
* **`AXPress` is not dependable** on the WebView2 tree (§2.3) — needs the key-event fallback.
* **The renderer accessibility tree is off by default and the enabler is empirical** (§2.6).
  This is the main risk.
* **The force-enabled tree is degraded** — checkbox state unreadable (§2.7).
* **Status cannot be changed while Teams is minimised or has no window** without first
  restoring the window (both mitigations work and neither steals focus).
* **429 handling is unverified** against a real rate-limit response (§3.3).
* Setting `AXValue`, `AXSelectedText`, `AXReplaceRangeWithText`, ⌘V, and menu-item `AXPress`
  all failed to modify the CKEditor field despite reporting success.

---

## 7. Accessibility selectors discovered

Teams **26183.1901.4874.5228**. Prefer `AXDOMIdentifier` where present — it is the DOM `id`
and the most stable handle. Never use child-index paths; they shifted between sessions
(the profile button moved from `…/0/0/0/1/1/1/0/0/0/0/0/0/0/0/0/0/5/0` to
`…/0/0/0/1/1/1/0/0/0/0/0/0/0/0/0/0/0/5/0` after a restart).

| Element | Selector |
|---|---|
| Profile / account button | `AXRole = AXButton` **and** `AXDescription` starts with `"Your profile"` — also `AXDOMIdentifier = idna-me-control-avatar-trigger`. Description embeds presence, e.g. `"Your profile, status Available "`. |
| Current status readout | `AXRole = AXTextField` **and** `AXDescription` starts with `"Your current status message"`. `AXValue` is the message; a second line `"Display until H:MM AM"` appears when a clear duration is set. |
| Edit status message | `AXRole = AXButton`, `AXDescription = "Edit status message"` |
| Delete status message | `AXRole = AXButton`, `AXDescription = "Delete status message"` |
| Set status message (no status yet) | `AXRole = AXMenuItem`, `AXDescription` contains `"set status message"` |
| **Compose box** | **`AXDOMIdentifier = "status-note-compose"`**; fallback `AXRole = AXTextArea` with `AXPlaceholderValue = "Type @ to mention someone in your status"`. `AXDOMClassList` includes `ck ck-content ck-editor__editable` (CKEditor 5). |
| Character counter | `AXRole = AXStaticText`, `AXValue` matches `N / 280` |
| Show when people message me | `AXRole = AXCheckBox`, `AXTitle = "Show when people message me"`, `AXDOMIdentifier = checkbox-rd2`. `AXValue` `"0"`/`"1"` — *unreadable on the degraded tree (§2.7)*. |
| Clear status message after | `AXRole = AXPopUpButton`, `AXTitle` starts `"Clear status message after"`; title suffix is the current choice. Options are `AXMenuItem`s titled `Never`, `Today`, `1 hour`, `4 hours`, `This week`, `Custom`. |
| Done | `AXRole = AXButton`, `AXTitle = "Done"` |
| Change presence (Available/Busy/…) | `AXRole = AXMenuItem`, `AXDescription = "Available, change status"` — *not used by this product, but available if you later want presence as well as the message.* |
| Native Edit menu | `AXMenuBar` → `AXMenuBarItem` `"Edit"` → items with stable ids: `Select All` `_NS:90`, `Paste` `_NS:76`. Readable without opening; **`AXPress` on them does nothing while backgrounded.** |

---

## 8. Focus and background-operation behaviour

**The operation does not steal focus, and this was measured rather than assumed.** Every run
of `set_status` records `NSWorkspace.frontmostApplication` before and after and prints
`focus PRESERVED` / `focus STOLEN`. Across every successful run — including window-restore and
window-reopen recoveries — the frontmost application was unchanged (`Code`, `Spotify`).

Why it works:

* `AXUIElementPerformAction` and `AXUIElementSetAttributeValue(kAXFocusedAttribute)` operate on
  the target process directly and do not activate it.
* `CGEvent.postToPid(_:)` delivers key events **to one process** rather than to the global
  event stream, so keystrokes never land in the user's foreground app.
* `CGEventSource(stateID: .privateState)` keeps synthetic modifier state out of the system's.
* Window restore (`AXMinimized = false`) and window reopen (AppleScript `reopen`) both leave the
  frontmost application alone.

The one visible side effect: the Teams profile flyout opens and closes on screen during the
~2–4 second update. If Teams is visible on a second monitor the user will see it flicker.
Worth measuring whether Teams can be updated less obtrusively; not solved here.

---

## 9. Security implications

1. **`.env` contains a Spotify client secret that this design does not need and must not ship.**
   `SPOTIFY_CLIENT_SECRET` is present in `<repo>/.env`.
   PKCE exists precisely so a distributed desktop app never holds a secret. `.env` *is*
   gitignored, so it has not been committed — but the secret has been sitting in plaintext on
   disk. **Recommendation: rotate it in the Spotify dashboard and delete the line.** The client
   ID alone is all the app needs and is not confidential.
2. **Accessibility permission is extremely powerful.** It lets the app read the full UI of every
   application and synthesise input anywhere. Users are right to be cautious; the app must
   explain precisely why it needs it and should be open-source or at minimum notarized and
   signed with a stable Team ID.
3. **Automation (Apple Events) permission** is separately required for the AppleScript paths
   (`reopen` for Teams, and the local Spotify source). macOS prompts per target application.
4. **Tokens** live in the Keychain, never in files or logs. The spike's `redact()` helper is the
   only permitted representation of a token in output. Keep that discipline.
5. **The pasteboard approach was rejected** — it did not work anyway, but it would also have
   clobbered the user's clipboard. Nothing in the working path touches it.
6. **Status messages are broadcast to colleagues.** Whatever the app writes is visible to the
   user's whole organisation. Track titles can be explicit, unprofessional, or personally
   revealing. This needs a kill switch, a "pause when in a meeting" behaviour, and probably a
   blocklist.

---

## 10. Corporate-Mac / MDM implications

This is the area I would most want your input on, because it is policy as much as engineering.

* **Teams here is signed, sandboxed, and corporate** — signed in as `a corporate tenant account (redacted)`.
  The status message is a corporate-visible field.
* **TCC grants can be centrally controlled.** An MDM can pre-approve Accessibility and Apple
  Events for a specific signed bundle id via a PPPC configuration profile — which makes fleet
  deployment feasible — but it can equally **deny** them, and many managed Macs restrict
  Accessibility precisely because it is a keylogging-capable permission. On a locked-down fleet
  this product may simply be un-installable.
* **No admin consent is required**, which was the point of the constraint: no Graph, no Azure app
  registration, no tenant admin. That constraint is satisfied.
* **But policy risk is not zero.** Automating the Teams client's UI is not something Microsoft
  supports, and some organisations' acceptable-use policies prohibit UI automation of corporate
  apps. Worth checking with your IT before wider distribution.
* **Teams updates are the standing threat.** Teams auto-updates frequently and the selectors are
  tied to accessible names Microsoft can change without notice. See §12.
* **Localisation.** Every selector except `AXDOMIdentifier` is an English UI string. On a
  non-English Teams, `"Edit status message"`, `"Done"`, `"Never"` and friends all change.
  `status-note-compose` and `checkbox-rd2` should survive; the rest will not.

---

## 11. Recommended production architecture

### Recommendation: **native Swift + SwiftUI, menu-bar only (`LSUIElement`)**. Not Tauri.

I evaluated the options against what this product actually is: a background agent with a tiny
menu-bar UI whose entire technical risk lives in macOS Accessibility APIs.

| Option | Assessment |
|---|---|
| **Swift / SwiftUI** ✅ | Direct, first-class access to `AXUIElement`, `AXObserver`, `CGEvent`, `NSWorkspace`, `NSRunningApplication` — every API the spike depends on, with no bridging layer. `NSStatusItem` for the menu bar. `SMAppService` for launch-at-login (macOS 13+). Keychain via Security.framework. Signing and notarization are the well-trodden path. Xcode 16.4 and Swift 6.1.2 are already installed. **The entire spike is already written in it.** |
| **Tauri 2** ❌ | The brief asked me not to pick it just because it was suggested, and the evidence does not support it. Tauri's value is a web UI — this app has essentially no UI. It would add a WebView runtime and a Rust↔JS boundary to ship a menu bar and a settings panel, and every line of the risky code would still have to cross FFI into `ApplicationServices`. That is strictly more moving parts for strictly less capability. Its cross-platform story is also weaker than it looks here, because the Teams backend must be rewritten for Windows UI Automation regardless. |
| **Rust + macOS bindings** ❌ for v1 | Viable (`objc2`, `core-foundation`, `accessibility-sys`) and genuinely attractive *if* Windows were a near-term commitment. But the AX work is finicky, under-documented, and needs fast iteration — exactly where Swift's first-party API surface pays for itself. Revisit if/when Windows becomes real. |
| **Electron** ❌ | Would ship a second Chromium to automate the first one. |
| **Python/`pyobjc` + `launchd`** ❌ | Fine for spikes, wrong for a signed, notarized, user-installed product. |

### Shape

```
PresenceSource  (protocol)          PresenceTarget (protocol)
  ├─ SpotifyWebAPISource                ├─ TeamsAXTarget      (macOS, this spike)
  ├─ SpotifyLocalAppleScriptSource      └─ (later) TeamsUIATarget (Windows)
  ├─ (later) AppleMusicSource
  ├─ (later) VSCode / Cursor / Claude Code
  └─ (later) GitHub
```

```swift
struct PresenceState {           // what a source produces
    let sourceID: String
    let isActive: Bool           // playing / focused / working
    let title: String            // "Dreams"
    let subtitle: String?        // "Fleetwood Mac"
    let itemID: String?          // identity for change detection
    let progress: (Duration, Duration)?
}

protocol PresenceSource: AnyObject {
    var id: String { get }
    func start(_ onChange: @escaping (PresenceState?) -> Void)
    func stop()
}

protocol PresenceTarget: AnyObject {
    var id: String { get }
    func currentStatus() async throws -> String?      // for save/restore
    func apply(_ rendered: String) async throws
    func restore(_ previous: String?) async throws
    var isAvailable: Bool { get }                     // Teams running & tree usable
}
```

Between them sits a **coordinator** that owns every behavioural requirement from the brief:

* renders `PresenceState → String` through a user-editable template, with the BMP sanitiser
  from §2.2 and the 280-character clamp from §2.4;
* **only writes when the rendered string changes** — not on every poll, not on progress ticks;
* **debounces** (suggest 5–8 s) so skipping through tracks produces one write, not ten;
* records the user's status at enable time and **restores it on disable**;
* detects manual edits (status no longer equals what we last wrote) and **backs off rather than
  fighting the user**;
* handles Teams absent / minimised / windowless via the §2.5 mitigations;
* watches for Teams restart via `NSWorkspace.didTerminateApplicationNotification` and re-runs the
  §2.6 enabler on relaunch.

Everything else the brief asked for is satisfied by the Swift choice: lightweight, menu-bar
native, no visible window, low CPU (event-driven plus a ~5 s poll), Keychain storage,
`SMAppService` launch-at-login, standard notarization.

---

## 12. Known brittle points

Ranked by how much they worry me.

1. **The accessibility-tree enabler (§2.6).** Empirical, not understood, and everything depends
   on it. Must be hardened first.
2. **The degraded force-enabled tree (§2.7).** `AXPress` dead, checkbox unreadable. Likely the
   same root cause as (1).
3. **Teams updates changing accessible names.** `AXDOMIdentifier` values (`status-note-compose`,
   `checkbox-rd2`, `idna-me-control-avatar-trigger`) are the most durable handles, but even those
   are not contractual. Needs a self-test that runs after every Teams version change and a
   loud, non-silent failure mode.
4. **Localisation.** English strings throughout (§10).
5. **CKEditor internals.** If Teams swaps its editor, the per-character typing path may need
   rework — though key events are the most human-like input available, so it should survive.
6. **Timing.** The flow uses fixed sleeps (0.12–1.2 s). These are tuned for an M1 Pro; they
   should become polled waits with deadlines everywhere before shipping.
7. **`checkbox-rd2`** looks auto-generated (`rd2` = render pass 2?). Treat as unstable and match
   on `AXTitle` as well.
8. **Spotify `localhost` ban and OAuth migration** — already handled, but Spotify is actively
   tightening auth rules; watch for further changes.
9. **429 unverified** (§3.3).

---

## 13. Windows-port considerations

* **The `PresenceTarget` abstraction is the right seam,** and the Spotify Web API source is
  fully portable — only the target and the local-app source are platform-specific.
* **Windows Teams is also WebView2**, so the same "renderer accessibility is off until an AT
  attaches" problem will very likely appear, in the UI Automation form. Expect to solve §2.6
  again in a different API.
* **UI Automation is a better API than macOS AX** for this: `AutomationId` maps to the same DOM
  ids seen here (`status-note-compose`), and `ValuePattern.SetValue` / `InvokePattern` are more
  reliable than `AXPress`. Text entry into CKEditor will still likely need `SendInput`.
* **No focus-free per-process input on Windows.** macOS's `CGEventPostToPid` has no clean Win32
  equivalent — `SendInput` is global and `PostMessage`/`WM_CHAR` to a Chromium HWND is
  unreliable. **Background updates without focus theft may not be achievable on Windows.** This
  is the single biggest portability unknown and should be spiked before promising it.
* **Language choice.** If Windows becomes a commitment, the honest options are a shared Rust
  core with two native shells, or two native apps sharing a design. Do not pick Tauri now on the
  theory that it makes Windows free — the hard part is the automation backend, and Tauri does
  not help with it.

---

## 14. GO / NO-GO

## **GO** — conditional on Phase 1 opening with the accessibility-enabler work.

The premise is proven on real software with a real account: Spotify state can be read, and the
real Teams status message can be changed, in the background, without disturbing the user, using
only capabilities available to a normal macOS user. No Graph, no Azure, no admin consent, no
browser extension, no hard-coded coordinates.

I would not call it GO without qualification, because §2.6 and §2.7 mean the automation is
currently reliable *in a state I can reach but cannot fully explain*. That is a solvable
engineering problem, not a dead end — but it must be solved first, not papered over.

**Decisions I need from you** are listed in the summary accompanying this report.
