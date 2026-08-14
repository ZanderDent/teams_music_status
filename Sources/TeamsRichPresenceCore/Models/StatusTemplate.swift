import Foundation

/// User-editable template that turns a `TrackPresence` into the Teams status string.
///
/// The default uses `♪` (U+266A) rather than `🎵`, because the astral emoji cannot be
/// delivered by the background input path — see `UnicodeSanitizer`. Users may still type
/// `🎵` into the template; it is substituted rather than rejected, and the live preview in
/// Settings shows exactly what Teams will receive.
public struct StatusTemplate: Equatable, Sendable {

    public static let defaultTemplate = "♪ {track} — {artists}"

    public enum Placeholder: String, CaseIterable, Sendable {
        case track = "{track}"
        case artist = "{artist}"
        case artists = "{artists}"
        case album = "{album}"

        public var explanation: String {
            switch self {
            case .track: return "Track title"
            case .artist: return "Primary artist only"
            case .artists: return "All artists, comma separated"
            case .album: return "Album name (may be empty)"
            }
        }
    }

    public var raw: String

    public init(_ raw: String = StatusTemplate.defaultTemplate) {
        self.raw = raw
    }

    /// Render, sanitize and clamp — the exact string that will be typed into Teams.
    public func render(_ presence: TrackPresence,
                       limit: Int = TeamsSelectors.statusCharacterLimit) -> String {
        let full = substitute(into: raw, presence: presence, includeAlbum: true)
        let sanitized = UnicodeSanitizer.sanitize(full).text

        guard sanitized.count > limit else { return sanitized }

        // Graceful degradation, in the order a person would do it:
        // 1. drop the optional album content, which is the least load-bearing part;
        if raw.contains(Placeholder.album.rawValue) {
            let withoutAlbum = substitute(into: raw, presence: presence, includeAlbum: false)
            let sanitizedShort = UnicodeSanitizer.sanitize(withoutAlbum).text
            if sanitizedShort.count <= limit { return sanitizedShort }
            // 2. still too long — truncate what remains.
            return UnicodeSanitizer.clamp(sanitizedShort, limit: limit)
        }
        return UnicodeSanitizer.clamp(sanitized, limit: limit)
    }

    private func substitute(into template: String,
                            presence: TrackPresence,
                            includeAlbum: Bool) -> String {
        var output = template
        output = output.replacingOccurrences(of: Placeholder.track.rawValue, with: presence.trackName)
        output = output.replacingOccurrences(of: Placeholder.artists.rawValue, with: presence.joinedArtists)
        output = output.replacingOccurrences(of: Placeholder.artist.rawValue, with: presence.primaryArtist)
        let album = includeAlbum ? (presence.albumName ?? "") : ""
        output = output.replacingOccurrences(of: Placeholder.album.rawValue, with: album)
        return tidySeparators(output)
    }

    /// An empty placeholder leaves orphaned punctuation behind — `"Song —  (from )"`.
    /// Clean up the shapes the supported placeholders can actually produce.
    private func tidySeparators(_ input: String) -> String {
        var output = input
        for _ in 0..<3 {
            output = output.replacingOccurrences(of: "()", with: "")
            output = output.replacingOccurrences(of: "[]", with: "")
            output = output.replacingOccurrences(of: "  ", with: " ")
        }
        // Trailing separator with nothing after it.
        let danglingSuffixes = [" —", " -", " ·", " |", " ("]
        var changed = true
        while changed {
            changed = false
            let trimmed = output.trimmingCharacters(in: .whitespaces)
            for suffix in danglingSuffixes where trimmed.hasSuffix(suffix.trimmingCharacters(in: .whitespaces)) {
                output = String(trimmed.dropLast(suffix.trimmingCharacters(in: .whitespaces).count))
                changed = true
                break
            }
        }
        return output.trimmingCharacters(in: .whitespaces)
    }

    /// Preview used by Settings so the user sees the real output before saving.
    public static let previewPresence = TrackPresence(
        trackName: "Dreams",
        artists: ["Fleetwood Mac"],
        albumName: "Rumours",
        isPlaying: true,
        trackID: "preview"
    )
}
