import Foundation

/// Makes text safe for the Teams status field.
///
/// Two independent constraints, both discovered empirically in Phase 0:
///
/// 1. **Astral-plane scalars are dropped in flight.** The background input path
///    (`CGEvent` + `keyboardSetUnicodeString`, posted to the Teams pid) silently discards
///    scalars above U+FFFF — `🎵` never arrives, whether sent per-character or in bulk.
///    Everything in the Basic Multilingual Plane arrives intact, including `♪` U+266A,
///    `♫` U+266B and the em dash `—` U+2014. Rather than lose the character, we substitute
///    a visually equivalent BMP symbol where one exists.
///
///    We do NOT work around this by activating Teams to paste: focus theft is a far worse
///    product defect than an emoji swap.
///
/// 2. **Teams caps the status at 280 characters**, shown live by its own counter.
public enum UnicodeSanitizer {

    /// Astral scalars worth preserving in some form, mapped to BMP equivalents.
    public static let astralSubstitutions: [Character: Character] = [
        "\u{1F3B5}": "\u{266A}",   // 🎵 musical note        -> ♪
        "\u{1F3B6}": "\u{266B}",   // 🎶 multiple notes      -> ♫
        "\u{1F3A7}": "\u{266A}",   // 🎧 headphone           -> ♪
        "\u{1F3B8}": "\u{266A}",   // 🎸 guitar              -> ♪
        "\u{1F3A4}": "\u{266A}",   // 🎤 microphone          -> ♪
        "\u{25B6}\u{FE0F}": "\u{25B6}",  // ▶️ -> ▶ (strip the variation selector)
        "\u{23F8}\u{FE0F}": "\u{23F8}",  // ⏸️ -> ⏸
    ]

    public struct Result: Equatable, Sendable {
        public let text: String
        /// Characters replaced with a BMP equivalent.
        public let substituted: Int
        /// Characters removed outright because no equivalent exists.
        public let dropped: Int

        public var wasModified: Bool { substituted > 0 || dropped > 0 }
    }

    /// Rewrite `input` so every character survives the synthetic-input path.
    public static func sanitize(_ input: String) -> Result {
        var output = String()
        var substituted = 0
        var dropped = 0

        for character in input {
            if let replacement = astralSubstitutions[character] {
                output.append(replacement)
                substituted += 1
                continue
            }
            // A character is deliverable only if every scalar in it is BMP. This keeps
            // combining sequences intact rather than half-delivering them.
            if character.unicodeScalars.allSatisfy({ $0.value <= 0xFFFF }) {
                output.append(character)
            } else {
                dropped += 1
            }
        }

        return Result(text: collapseWhitespace(output), substituted: substituted, dropped: dropped)
    }

    /// Dropping a character can leave doubled or trailing spaces (`"🎵 Song"` -> `" Song"`).
    static func collapseWhitespace(_ input: String) -> String {
        var output = ""
        var lastWasSpace = false
        for character in input {
            let isSpace = character == " "
            if isSpace && lastWasSpace { continue }
            output.append(character)
            lastWasSpace = isSpace
        }
        return output.trimmingCharacters(in: .whitespaces)
    }

    /// Clamp to `limit` characters, never splitting a grapheme cluster.
    ///
    /// Counting is by `Character` (grapheme cluster), which matches what Teams' own
    /// counter reported in testing: `"♪ Dreams — Fleetwood Mac"` showed as `24 / 280`.
    public static func clamp(_ input: String, limit: Int = TeamsSelectors.statusCharacterLimit) -> String {
        guard limit > 0 else { return "" }
        guard input.count > limit else { return input }
        // Reserve one character for the ellipsis so the result still fits.
        let keep = max(0, limit - 1)
        let truncated = String(input.prefix(keep))
        // Avoid ending on a dangling space before the ellipsis.
        return truncated.trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
