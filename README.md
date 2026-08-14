# Teams Rich Presence

Discord-style rich presence for Microsoft Teams on macOS. It shows what you're listening
to as your Teams custom status message:

```
♪ Dreams — Fleetwood Mac
```

A small menu-bar utility. No Dock icon, no window unless you ask for one.

> **Status:** early. macOS only. Works on the machine it was built and tested on;
> not yet signed for distribution. See [Known limitations](#known-limitations).

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

* macOS 14 or later (Apple silicon or Intel)
* Microsoft Teams (the `com.microsoft.teams2` client), signed in
* Spotify — either an account for the Web API, or the desktop app for the local source
* Xcode 16 / Swift 6.1 to build

---

## Local development setup

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

That builds the SwiftPM executable, wraps it in `TeamsRichPresence.app`, signs it, and
launches it. The app appears in the menu bar.

For a faster inner loop you can also work with the package directly:

```sh
swift build           # compile
swift test            # unit tests (no Teams or Spotify needed)
swift run trpctl      # diagnostics CLI, see below
```

### 3. Grant permissions

On first launch the app explains what it needs and links straight to the right settings
pane. See [Permissions](#permissions).

### Signing

`build-app.sh` signs with the first `Apple Development` identity it finds; override with
`CODESIGN_IDENTITY`. Use a **stable** identity: macOS ties the Accessibility grant to the
code signature, so re-signing ad hoc makes you re-grant permission on every build.

---

## `trpctl` — the diagnostics CLI

The same production code, drivable from a terminal. Useful when something is not working
and you want to know exactly which step failed.

```sh
swift run trpctl health      # is Teams automatable right now, and if not, why
swift run trpctl enable      # run the accessibility enabler and report before/after
swift run trpctl selftest    # check every Teams selector still resolves
swift run trpctl get         # read the current Teams status message
swift run trpctl set "♪ Test"  # write one, and verify it landed
swift run trpctl gate        # the full acceptance matrix (add --with-restart)
swift run trpctl version     # installed Teams version
```

`trpctl gate` is the acceptance harness described in
[`docs/ACCEPTANCE_TESTS.md`](docs/ACCEPTANCE_TESTS.md). It changes your real Teams status
and puts it back afterwards.

---

## Permissions

### Accessibility — required

Teams Rich Presence uses the macOS Accessibility API to open your Teams profile menu and
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

* **Updates only when the rendered status actually changes.** Progress ticks, the same
  track looping, and repeated polls do not touch Teams.
* **Debounces changes** (5s by default), so skipping through tracks produces one Teams
  edit rather than ten.
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

Default: `♪ {track} — {artists}`

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
* **The Teams profile flyout is briefly visible** during an update (~2–4 seconds). If
  Teams is on a second monitor you will see it.
* **Not notarized.** You will need to build it yourself for now.

---

## Privacy and security

* **Nothing leaves your Mac** except the Spotify API calls the app makes on your behalf.
  No telemetry, no analytics, no backend, no account.
* **Spotify tokens live in the macOS Keychain**, never in files, `UserDefaults`, or logs.
  The only thing ever logged about a token is its length.
* **No client secret.** OAuth uses PKCE, which exists precisely so a desktop app does not
  need one. The client ID is public by design and safe to bundle.
* **Minimum scope.** Only `user-read-currently-playing` is requested.
* **Your status is visible to your whole organisation.** Track titles can be explicit or
  personal. The menu-bar toggle is the kill switch; consider what you play.

---

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Bug reports that include the output of
`swift run trpctl selftest` are enormously more useful than ones that don't.

## License

MIT — see [`LICENSE`](LICENSE).

Not affiliated with, endorsed by, or sponsored by Microsoft or Spotify.
