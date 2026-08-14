# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Use GitHub's private reporting instead:
[**Report a vulnerability**](https://github.com/ZanderDent/teams_music_status/security/advisories/new).
If that is unavailable to you, open an issue saying only that you have a security report
and asking for a contact route — no details.

You should get an acknowledgement within a week. Because this is a spare-time project,
please allow a reasonable window for a fix before disclosing publicly.

## What this app can access

Being clear about this matters, because the permissions look alarming and deserve to be
understood rather than trusted blindly.

| | |
|---|---|
| **Accessibility** | Required. It is how the app opens the Teams profile menu and types your status. macOS grants this at the whole-system level, so the app *could* read other applications' interfaces. It does not: it only ever reads and drives Microsoft Teams, and every element it touches is listed in [`TeamsSelectors.swift`](Sources/TeamsMusicStatusCore/Targets/Teams/TeamsSelectors.swift). |
| **Automation (Apple Events)** | Optional, only for the Local Spotify source. Used to ask the Spotify app what is playing. |
| **Network** | Only `accounts.spotify.com` and `api.spotify.com`, and only when the Spotify Web API source is selected. |
| **Keyboard input** | The app synthesises keystrokes, but sends them to the Teams process specifically via `CGEvent.postToPid` — never to the global event stream. It does not read your keyboard. |

## What it stores, and where

* **Spotify OAuth tokens** — macOS Keychain only, service `com.zanderdent.TeamsMusicStatus.spotify`.
  Never in files, `UserDefaults`, or logs.
* **Preferences** — `UserDefaults`. Non-sensitive: template, source choice, timings.
* **Your previous Teams status** — `UserDefaults`, so it can be restored after a restart.
  Plain text, and it is your own status message.

There is **no client secret**. Authentication is OAuth 2.0 with PKCE, which exists so a
desktop app does not need one. The Spotify client ID is public by design.

There is **no backend, no telemetry and no analytics**. Nothing leaves your Mac except
the Spotify API calls the app makes on your behalf.

## Logging

Access tokens, refresh tokens, authorization codes and PKCE verifiers are never logged,
at any level. The only permitted representation of a secret is its length, via
`Redact.secret`. CI fails the build if a token becomes reachable by a logger.

Logs do contain your status text, which is personal — read them before pasting into a bug
report.

## Things worth knowing

* **Your Teams status is visible to your whole organisation.** Track titles can be
  explicit or revealing. The menu-bar toggle is the kill switch.
* **Automating a corporate Teams client may conflict with your employer's policy.** That
  is between you and them; check before installing it on a managed Mac.
* **Releases are not yet notarized.** Build from source and check the diff.
