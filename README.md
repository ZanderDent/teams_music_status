# Teams Music Status

[![CI](https://github.com/ZanderDent/teams_music_status/actions/workflows/ci.yml/badge.svg)](https://github.com/ZanderDent/teams_music_status/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

Discord-style rich presence for Microsoft Teams on macOS. It shows what you're listening
to as your Teams custom status message:

```
♪ Dreams by Fleetwood Mac
```

A small menu-bar utility. No Dock icon, no window unless you ask for one.

Teams Music Status, developed by Zander Dent.

> **Status:** v1.0.0. macOS 14+. Signed with a Developer ID certificate and notarized by
> Apple, so it installs and opens normally. See [Known limitations](#known-limitations).

<!-- TODO: screenshot of the menu-bar panel, and a short screen recording of a track
     change updating the Teams status. -->

---

## Why this exists, and how it works

Microsoft Teams has no public API for the custom status message that does not require
Microsoft Graph, an Azure app registration, and — in most organisations — a tenant
administrator's consent. None of that is available to a normal user who just wants their
status to say what they're playing.

So this app does what you would do by hand: it opens your Teams profile menu, clicks
**Set status message**, types, and presses **Done** — through the macOS Accessibility
API, in the background, without taking focus away from whatever you're working on.

That approach was validated before any product code was written. The evidence, including
everything that *didn't* work, is in [`docs/FEASIBILITY.md`](docs/FEASIBILITY.md).

**No Microsoft Graph. No Azure app registration. No admin consent. No browser extension.
No screen coordinates.**

---

## Requirements

* **macOS 14 (Sonoma) or later** — Apple silicon or Intel
* Microsoft Teams (the `com.microsoft.teams2` client), signed in
* Spotify — either an account for the Web API, or the desktop app for the local source

---

## Install

1. Download `Teams-Music-Status-1.0.0-macOS.dmg` from the
   [latest release](https://github.com/ZanderDent/teams_music_status/releases/latest).
2. Open the DMG and drag **Teams Music Status** into **Applications**.
3. Launch it from Applications. It appears in the menu bar as ♪ — there is no Dock icon.
4. A setup window walks you through the rest:
   * **Allow Accessibility access** — this is how the app types your Teams status.
     macOS will open System Settings; switch on **Teams Music Status**. The window ticks
     itself once you do.
   * **Connect Spotify** — signs in through your browser, once.
   * **Microsoft Teams** — confirms Teams is running.
5. Press **Start Syncing**. Play something, and your Teams status follows.

To verify the download:

```sh
shasum -a 256 Teams-Music-Status-1.0.0-macOS.dmg
```

and compare it with the `.sha256` published alongside the DMG.

### Uninstalling

Drag the app to the Trash, or run `./scripts/uninstall.sh` from a clone to also remove
preferences, Keychain tokens and the permission grants.

---

## Building from source

You only need this if you want to develop the app. Users should use the DMG above.

### 1. Get a Spotify client ID

Spotify's Web API needs an application registration. This is free and takes a minute.

1. Go to the [Spotify developer dashboard](https://developer.spotify.com/dashboard) and
   create an app.
2. Add this **exact** redirect URI:

   ```
   http://127.0.0.1:8888/callback
   ```

   Spotify stopped accepting `localhost` as a redirect host on 27 November 2025. It must
   be the loopback IP literal.
3. Copy the **Client ID**. You do **not** need the client secret — this app uses OAuth
   with PKCE and never uses a secret. If you already created one, it is unused here.

### 2. Build and run

```sh
git clone https://github.com/ZanderDent/teams_music_status.git
cd teams_music_status

export SPOTIFY_CLIENT_ID=your_client_id_here
./scripts/build-app.sh --run
```

That builds the SwiftPM executable, wraps it in `TeamsMusicStatus.app`, signs it with a
local development certificate, and launches it. The app appears in the menu bar.

To build a distributable DMG instead, see [`docs/DISTRIBUTION.md`](docs/DISTRIBUTION.md):

```sh
./scripts/release.sh --notarize     # requires a Developer ID certificate
./scripts/release.sh --unsigned     # local testing only
```

For a faster inner loop you can also work with the package directly:

```sh
swift build           # compile
swift test            # unit tests (no Teams or Spotify needed)
swift run tmsctl      # diagnostics CLI, see below
```

### 3. Grant permissions

On first launch a setup window walks through it: allow Accessibility, connect Spotify,
confirm Teams is running. Each step verifies itself — the Spotify step turns green only
after it has actually read what is playing, and shows you the status it will set.

### Uninstalling

```sh
./scripts/uninstall.sh
```

Removes the app, its preferences, the Spotify tokens in the Keychain, both permission
grants, the login item and its caches. Use `--keep-app` to reset everything *except* the
bundle, which is how you test the first-run experience again.

### Signing

`build-app.sh` signs with the first `Apple Development` identity it finds; override with
`CODESIGN_IDENTITY`. Use a **stable** identity: macOS ties the Accessibility grant to the
code signature, so re-signing ad hoc makes you re-grant permission on every build.

---

## `tmsctl` — the diagnostics CLI

The same production code, drivable from a terminal. Useful when something is not working
and you want to know exactly which step failed.

```sh
swift run tmsctl health      # is Teams automatable right now, and if not, why
swift run tmsctl enable      # run the accessibility enabler and report before/after
swift run tmsctl selftest    # check every Teams selector still resolves
swift run tmsctl get         # read the current Teams status message
swift run tmsctl set "♪ Test"  # write one, and verify it landed
swift run tmsctl gate        # the full acceptance matrix (add --with-restart)
swift run tmsctl version     # installed Teams version
```

`tmsctl gate` is the acceptance harness described in
[`docs/ACCEPTANCE_TESTS.md`](docs/ACCEPTANCE_TESTS.md). It changes your real Teams status
and puts it back afterwards.

---

## Permissions

### Accessibility — required

Teams Music Status uses the macOS Accessibility API to open your Teams profile menu and
type your status, exactly as you would.

It does **not** read your Teams messages, and it does **not** capture your keyboard.
Keystrokes are delivered to the Teams process specifically, so whatever you are typing in
never sees them and your frontmost app never changes.

Grant it in **System Settings ▸ Privacy & Security ▸ Accessibility**.

### Automation (Apple Events) — only for the local Spotify source

Needed only if you choose **Local Spotify**, which reads the Spotify app on this Mac.
macOS asks the first time it is used. The Spotify Web API source does not need it.

---

## Choosing a music source

| | Spotify Web API (default) | Local Spotify app |
|---|---|---|
| Sign-in | One-time OAuth in your browser | None |
| Sees playback on your phone / web player | Yes | No |
| Works offline | No | Yes |
| Artists | All of them | Primary artist only |
| Extra permission | None | Automation |

Both implement the same `PresenceSource` interface, so switching is a menu choice.

---

## How it behaves

* **Updates within a few seconds of a track change.** Measured end to end on the
  development Mac: skip a track, Teams shows the new one in **4–5 seconds**.
* **Updates only when the rendered status actually changes.** Progress ticks, the same
  track looping, and repeated polls do not touch Teams.
* **Rate-limits rather than delays.** The first change after a quiet period is published
  immediately; only a second change arriving within a few seconds waits. Skipping through
  ten tracks still produces one or two Teams edits, not ten.
* **Pausing does not immediately clear your status.** After a grace period (5 minutes by
  default) your previous status is restored. Resuming sooner changes nothing.
* **Restores your original status** when you turn syncing off — but only if Teams still
  shows what the app wrote. If you typed something yourself, that is yours and it stays.
* **Notices manual edits.** If your Teams status stops matching what the app last wrote,
  it stops overwriting and offers a *Resume automatic updates* button.
* **Recovers on its own** from Teams being minimized, having no open window, or being
  quit and relaunched.
* **Sets the Teams clear-duration to `Never`**, so your status does not silently expire.

### Status template

Default: `♪ {track} by {artists}`

| Placeholder | Meaning |
|---|---|
| `{track}` | Track title |
| `{artist}` | Primary artist only |
| `{artists}` | All artists, comma separated |
| `{album}` | Album name (may be empty) |

Output is clamped to Teams' 280-character limit — the album is dropped before anything is
truncated, and truncation never splits a character.

**About `🎵`:** the background input path cannot deliver emoji above the Basic Multilingual
Plane; they are silently dropped in flight. Rather than steal focus to work around that,
the app substitutes an equivalent (`🎵 → ♪`, `🎶 → ♫`). That is why the default template
uses `♪`.

---

## Architecture

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the detail. In short:

```
SpotifyWebAPISource ─┐
                     ├─ PresenceCoordinator ─ TeamsAXTarget ─ Microsoft Teams
SpotifyLocalSource ──┘        │
                              └─ SyncEngine (pure decision logic, unit tested)
```

`PresenceSource` and `PresenceTarget` are the seams. Adding Apple Music, or a Windows
Teams target built on UI Automation, means writing one conformance rather than touching
the core.

---

## Known limitations

* **macOS only.** A Windows port would need a different automation backend, and
  background updates without focus theft may not be achievable there — see
  `docs/FEASIBILITY.md` §13.
* **"Show when people message me" cannot be set reliably.** Teams exposes the checkbox
  but not its checked state (`AXValue` is always empty), so the app refuses to toggle it
  blind rather than risk turning your setting off. Tick it once in Teams by hand.
* **English Teams only.** Most selectors key on DOM identifiers, but several rely on
  English accessible names. A non-English Teams will fail the selector self-test rather
  than misbehave.
* **Teams updates can break it.** The self-test runs whenever the Teams version changes
  and disables automation with a clear message instead of thrashing.
* **The Teams profile flyout is briefly visible** during an update (~3 seconds). If Teams
  is on a second monitor you will see it open and close. It is not brought to the front,
  and it never takes keyboard focus.
* **Builds you make yourself are not notarized.** Released DMGs are signed with a
  Developer ID certificate and notarized by Apple, so they open with no warning at all. A
  build from source is signed with whatever local certificate you have, which Gatekeeper
  will refuse on any other Mac. Note that macOS 15 removed the old right-click → Open
  bypass: getting past it now means System Settings → Privacy & Security → **Open Anyway**.
  Use a release build unless you are developing.

---

## Privacy and security

This app is local-first by design. Specifically:

* **Microsoft Teams is automated locally**, through the macOS Accessibility API. There is
  **no Microsoft Graph integration**, no Azure app registration and no admin consent —
  the app drives the Teams window on your Mac exactly as you would.
* **Spotify Web API traffic goes from your Mac straight to Spotify.** Nothing proxies it.
* **Local Spotify mode uses Apple Events** to ask the Spotify app on your Mac what is
  playing. That never touches the network.
* **No backend belonging to this project receives anything.** There isn't one.
* **No analytics and no telemetry**, of any kind.

And:

* **Nothing leaves your Mac** except the Spotify API calls the app makes on your behalf.
  No account, no sign-up.
* **Spotify tokens live in the macOS Keychain**, never in files, `UserDefaults`, or logs.
  The only thing ever logged about a token is its length.
* **No client secret.** OAuth uses PKCE, which exists precisely so a desktop app does not
  need one. The client ID is public by design and safe to bundle.
* **Minimum scope.** Only `user-read-currently-playing` is requested.
* **Your status is visible to your whole organisation.** Track titles can be explicit or
  personal. The menu-bar toggle is the kill switch; consider what you play.

---

## Security

See [`SECURITY.md`](SECURITY.md) for what the app can access, what it stores, and how to
report a vulnerability privately.

## Contributing

Pull requests welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md). Bug reports that include the output of
`swift run tmsctl selftest` are enormously more useful than ones that don't.

## License

MIT — see [`LICENSE`](LICENSE).

Not affiliated with, endorsed by, or sponsored by Microsoft or Spotify.
