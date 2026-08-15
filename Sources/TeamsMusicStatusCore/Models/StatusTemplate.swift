import Foundation

/// User-editable template that turns a `TrackPresence` into the Teams status string.
///
/// The default uses `♪` (U+266A) rather than `🎵`, because the astral emoji cannot be
/// delivered by the background input path — see `UnicodeSanitizer`. Users may still type
/// `🎵` into the template; it is substituted rather than rejected, and the live preview in
/// Settings shows exactly what Teams will receive.
public struct StatusTemplate: Equatable, Sendable {

    public static let defaultTemplate = "♪ {track} by {artists}"

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
    ///
    /// `maskProfanity` applies only to the track, artist and album values, never to the
    /// template the user wrote themselves: if someone deliberately types a rude word into
    /// their own template, that is their call. Track titles are the part nobody chose.
    public func render(_ presence: TrackPresence,
                       limit: Int = TeamsSelectors.statusCharacterLimit,
                       maskProfanity: Bool = true) -> String {
        let full = substitute(into: raw, presence: presence,
                              includeAlbum: true, maskProfanity: maskProfanity)
        let sanitized = UnicodeSanitizer.sanitize(full).text

        guard sanitized.count > limit else { return sanitized }

        // Graceful degradation, in the order a person would do it:
        // 1. drop the optional album content, which is the least load-bearing part;
        if raw.contains(Placeholder.album.rawValue) {
            let withoutAlbum = substitute(into: raw, presence: presence,
                                          includeAlbum: false, maskProfanity: maskProfanity)
            let sanitizedShort = UnicodeSanitizer.sanitize(withoutAlbum).text
            if sanitizedShort.count <= limit { return sanitizedShort }
            // 2. still too long — truncate what remains.
            return UnicodeSanitizer.clamp(sanitizedShort, limit: limit)
        }
        return UnicodeSanitizer.clamp(sanitized, limit: limit)
    }

    /// Whether masking would change what this template renders for this track — used by
    /// Settings to show the user that a substitution happened rather than leaving them to
    /// wonder why the title looks odd.
    public func wouldMaskProfanity(_ presence: TrackPresence) -> Bool {
        render(presence, maskProfanity: false) != render(presence, maskProfanity: true)
    }

    /// Separator tokens that may sit between two placeholders and become orphaned when
    /// the one after them is empty — `"♪ Untitled by"` with no artist.
    private static let separators = ["—", "–", "-", "·", "|", "by", "with", "feat.", "feat", "from"]

    private func substitute(into template: String,
                            presence: TrackPresence,
                            includeAlbum: Bool,
                            maskProfanity: Bool) -> String {
        var output = template
        // Longest placeholder first: `{artist}` is a prefix of `{artists}`, and
        // substituting the short one first would turn `{artists}` into "Dom Dollas".
        let values: [(Placeholder, String)] = [
            (.artists, presence.joinedArtists),
            (.artist, presence.primaryArtist),
            (.track, presence.trackName),
            (.album, includeAlbum ? (presence.albumName ?? "") : ""),
        ].map { maskProfanity ? ($0.0, ProfanityFilter.mask($0.1)) : $0 }

        for (placeholder, value) in values {
            if value.isEmpty {
                // Remove the placeholder *and* any separator that introduces it, before
                // substitution rather than by stripping trailing words afterwards. A
                // post-hoc strip of a trailing " by" would also mangle a track genuinely
                // called "Get by".
                output = removePlaceholder(placeholder, from: output)
            } else {
                output = output.replacingOccurrences(of: placeholder.rawValue, with: value)
            }
        }
        return tidySeparators(output)
    }

    private func removePlaceholder(_ placeholder: Placeholder, from template: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: placeholder.rawValue)
        let separatorAlternation = Self.separators
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // Optional leading separator, then the placeholder.
        let pattern = "(?:\\s*(?:\(separatorAlternation)))?\\s*\(escaped)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return template.replacingOccurrences(of: placeholder.rawValue, with: "")
        }
        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        return regex.stringByReplacingMatches(in: template, range: range, withTemplate: "")
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

    /// Preview for the masking toggle. `previewPresence` is clean, so it cannot show what
    /// the toggle does; this one moves visibly when it is switched.
    public static let profanityPreviewPresence = TrackPresence(
        trackName: "Thank Fuck It's The Weekend",
        artists: ["The Weekenders"],
        albumName: nil,
        isPlaying: true,
        trackID: "preview-masked"
    )
}
