import Foundation

/// Masks profanity in a status before it reaches Teams.
///
/// Your Teams status is visible to your whole organisation, and track titles are written
/// by people who were not thinking about your colleagues. Masking is on by default for
/// that reason: the cost of a false positive is a slightly odd-looking title, and the
/// cost of a false negative is an expletive on your work profile.
///
/// ## The Scunthorpe problem
///
/// The obvious implementation — substring search — is wrong, and famously so. "Scunthorpe"
/// contains a slur; "class", "Cassandra" and "assassin" contain another; "shiitake"
/// contains a third. Matching on substrings would mangle ordinary track and artist names.
///
/// So matching is **whole words only**, using word boundaries. `ProfanityFilterTests`
/// pins the cases that would break if anyone changes that.
///
/// This is deliberately a small, fixed list of common English profanity. It is not a
/// content-moderation system, it does not try to catch every creative spelling, and it
/// makes no attempt at slurs in other languages — claiming otherwise would give a false
/// sense of safety. Anyone who needs certainty should turn the integration off for the
/// track, or leave masking on and check what it produced.
public enum ProfanityFilter {

    /// Strong English profanity and unambiguous slurs, lower-cased. Whole words only.
    ///
    /// Kept intentionally short, and limited to words that would actually be a problem on
    /// a colleague's work profile. Mild words are deliberately absent:
    ///
    /// - `damn` would mask Kendrick Lamar's *DAMN.*
    /// - `dick` would mask *Moby Dick* and anyone named Dick
    /// - `cock`, `prick`, `crap`, `bugger` all have ordinary meanings
    ///
    /// Masking those is a visible, confusing bug on a real album title, and the harm
    /// avoided is close to zero. Every addition here is a potential false positive, so the
    /// bar is "would this genuinely embarrass someone in front of their organisation".
    ///
    /// Words with common innocent meanings are also excluded from the slur set for the
    /// same reason — `dyke` (Offa's Dyke) and `chink` (a chink of light) would fire on
    /// ordinary titles.
    static let words: Set<String> = [
        "fuck", "fucks", "fucked", "fucking", "fuckin", "fucker", "fuckers",
        "motherfucker", "motherfuckers", "motherfucking", "motherfuckin",
        "shit", "shits", "shitty", "shitting", "bullshit",
        "bitch", "bitches", "bitching",
        "cunt", "cunts",
        "piss", "pissed", "pissing",
        "bastard", "bastards",
        "whore", "whores", "slut", "sluts",
        "asshole", "assholes", "arsehole", "arseholes",
        "twat", "twats", "wanker", "wankers",
        "nigga", "niggas", "nigger", "niggers",
        "faggot", "faggots",
    ]

    /// Built once: compiling this per status update would be wasteful, and the word list
    /// never changes at runtime.
    private static let regex: NSRegularExpression? = {
        // Longest first so "motherfucker" wins over "fucker" and the whole word is masked.
        let alternation = words
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // \b on both sides is what avoids the Scunthorpe problem.
        return try? NSRegularExpression(pattern: "\\b(?:\(alternation))\\b",
                                        options: [.caseInsensitive])
    }()

    /// Replace profanity with a masked form, preserving the original casing and length.
    ///
    /// `fuck` becomes `f**k`, `Shit` becomes `S**t`, `FUCKING` becomes `F*****G`. The
    /// first and last characters survive so the title still reads naturally and the
    /// masking is obviously deliberate rather than looking like corrupted text.
    public static func mask(_ text: String) -> String {
        guard let regex, !text.isEmpty else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        var result = text
        // Replace back to front so earlier ranges stay valid.
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(matchRange, with: masked(String(result[matchRange])))
        }
        return result
    }

    /// Whether masking would change this text — used by the UI to explain itself.
    public static func containsProfanity(_ text: String) -> Bool {
        guard let regex, !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    /// `fuck` → `f**k`. Keeps the outer letters, masks the middle.
    private static func masked(_ word: String) -> String {
        let characters = Array(word)
        switch characters.count {
        case 0: return word
        case 1, 2:
            // Too short to keep both ends and still hide anything.
            return String(characters[0]) + String(repeating: "*", count: characters.count - 1)
        default:
            return String(characters.first!)
                + String(repeating: "*", count: characters.count - 2)
                + String(characters.last!)
        }
    }
}
