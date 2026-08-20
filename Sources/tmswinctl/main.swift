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
      render [template]      render the status text for what is playing now
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

case "version":
    print("tmswinctl (Teams Music Status, Windows)")

default:
    usage()
}
