import Foundation
import TeamsMusicStatusCore
import TeamsMusicStatusWindows

// Diagnostics harness for the Windows port — the counterpart of `tmsctl` on macOS. It
// drives the real product code from a terminal so each layer can be exercised and verified
// on its own, without a GUI and without guessing.

func usage() -> Never {
    print("""
    tmswinctl — Teams Music Status diagnostics (Windows)

      now-playing            read the system media session
      teams-status           read the Teams status message (opens and closes the flyout)
      teams-selectors        resolve every Teams selector and name any that broke
      teams-dump [needle]    list what Teams is exposing right now
      render [template]      render the status text for what is playing now
      teams-try-text <text>  try text entry without committing (Done is not pressed)
      teams-set <text>       write and commit a status message
      teams-clear            remove the status message
      sync-once [template]   read what is playing, render it, publish it, verify
      gate                   Hard Gate 0 acceptance matrix (writes and restores status)
      health                 Teams version, health state, frontmost window
      version

    Default template: \(StatusTemplate.defaultTemplate)
    """)
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

/// Reads presence once, reporting "nothing is playing" as the normal state it is rather
/// than as a failure.
func currentPresence() -> TrackPresence? {
    let source = WindowsMediaSource()
    do {
        return try source.read()
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

switch command {
case "now-playing":
    let source = WindowsMediaSource()
    guard let presence = currentPresence() else {
        print("nothing is playing")
        exit(0)
    }
    print("source     : \(source.displayName)")
    print("appId      : \(source.currentAppID() ?? "<unknown>")")
    print("track      : \(presence.trackName)")
    print("artists    : \(presence.joinedArtists)  (primary: \(presence.primaryArtist))")
    print("album      : \(presence.albumName ?? "<none>")")
    print("playing    : \(presence.isPlaying)")
    print("identity   : \(presence.identity)")

case "render":
    let template = StatusTemplate(arguments.count > 1 ? arguments[1] : StatusTemplate.defaultTemplate)
    guard let presence = currentPresence() else {
        print("nothing is playing — nothing to render")
        exit(0)
    }
    let rendered = template.render(presence)
    print("template   : \(template.raw)")
    print("rendered   : \(rendered)")
    print("length     : \(rendered.count) / \(TeamsSelectors.statusCharacterLimit)")
    if template.wouldMaskProfanity(presence) {
        print("note       : profanity masking changed this text")
    }

case "teams-status":
    let target = TeamsWindowsTarget()
    print("availability : \(target.availability())")
    do {
        let status = try target.readCurrentStatus()
        print("status       : \(status ?? "<none set>")")
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case "teams-selectors":
    let target = TeamsWindowsTarget()
    do {
        var broken: [String] = []
        for entry in try target.selectorReport() {
            let mark = entry.resolved ? "ok  " : "MISS"
            print("\(mark) \(entry.name)\(entry.detail.map { "  → \($0)" } ?? "")")
            if !entry.resolved { broken.append(entry.name) }
        }
        // `setStatusItem` and `statusReadout` are mutually exclusive — Teams shows one or
        // the other depending on whether a status is already set — so a miss on exactly
        // one of them is expected, not a regression.
        let expectedMisses: Set<String> = ["setStatusItem", "statusReadout",
                                           "editStatusButton", "deleteStatusButton"]
        let unexpected = broken.filter { !expectedMisses.contains($0) }
        print(unexpected.isEmpty
              ? "\nall required selectors resolved"
              : "\nBROKEN: \(unexpected.joined(separator: ", "))")
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case "teams-dump":
    let target = TeamsWindowsTarget()
    let needle = arguments.count > 1 ? arguments[1].lowercased() : nil
    do {
        let rows = try target.snapshotSummary()
        print("snapshot: \(rows.count) elements")
        for row in rows {
            if let needle,
               !row.name.lowercased().contains(needle), !row.domID.lowercased().contains(needle) {
                continue
            }
            guard !row.name.isEmpty || !row.domID.isEmpty else { continue }
            print("  \(row.role.padding(toLength: 14, withPad: " ", startingAt: 0)) \(row.name)\(row.domID.isEmpty ? "" : "  [\(row.domID)]")")
        }
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case "teams-try-text":
    // Exercises text entry against the real compose box and reports what landed. Stops
    // short of Done, so the user's published status is untouched.
    let text = arguments.count > 1 ? arguments[1] : "♫ probe — text entry"
    let target = TeamsWindowsTarget()
    do {
        print("attempting: \(text)")
        for result in try target.probeTextEntry(text) {
            let landed = result.readBack.map { "'\($0)'" } ?? "<empty>"
            let match = result.readBack == text ? "  <-- matches" : ""
            print("  \(result.method.padding(toLength: 28, withPad: " ", startingAt: 0)) \(landed)\(match)")
        }
        print("\n(Done was not pressed — the published status is unchanged.)")
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case "teams-set":
    // Writes and commits. Prints the previous status first so it can always be put back.
    guard arguments.count > 1 else {
        FileHandle.standardError.write(Data("usage: tmswinctl teams-set <text>\n".utf8))
        exit(2)
    }
    let target = TeamsWindowsTarget()
    do {
        let previous = try target.readCurrentStatus()
        print("previous : \(previous ?? "<none set>")")
        try target.apply(status: arguments[1])
        print("wrote    : \(arguments[1])")
        print("readback : \(try target.readCurrentStatus() ?? "<none set>")")
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case "teams-clear":
    let target = TeamsWindowsTarget()
    do {
        print("previous : \(try target.readCurrentStatus() ?? "<none set>")")
        try target.clearStatus()
        print("readback : \(try target.readCurrentStatus() ?? "<none set>")")
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case "sync-once":
    // The whole product in one shot: read what is playing, render it, publish it, verify.
    let template = StatusTemplate(arguments.count > 1 ? arguments[1] : StatusTemplate.defaultTemplate)
    let target = TeamsWindowsTarget()
    guard let presence = currentPresence(), presence.isPlaying else {
        print("nothing is playing — no write")
        exit(0)
    }
    let rendered = template.render(presence)
    do {
        print("playing  : \(presence.trackName) — \(presence.joinedArtists)")
        print("previous : \(try target.readCurrentStatus() ?? "<none set>")")
        try target.apply(status: rendered)
        print("published: \(rendered)")
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case "gate":
    // Hard Gate 0. Required by CONTRIBUTING.md before opening a pull request that touches
    // the Teams automation. Writes and restores the user's status; exits non-zero if any
    // case fails or if anything stole the foreground.
    GateRunner(target: TeamsWindowsTarget()).run(arguments: arguments)

case "health":
    print("teams version : \(TeamsWindowsHealth.teamsVersion() ?? "unknown")")
    print("health        : \(TeamsWindowsHealth.current().explanation)")
    print("frontmost     : \(WindowsFocus.frontmostTitle())")

case "version":
    print("tmswinctl (Teams Music Status, Windows)")
    print("teams   : \(TeamsWindowsHealth.teamsVersion() ?? "unknown")")

default:
    usage()
}
