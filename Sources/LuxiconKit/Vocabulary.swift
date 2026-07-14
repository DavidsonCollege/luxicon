import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// One user-vocabulary term: canonical spelling plus optional known
/// mishearings and agent-facing metadata (see `VocabularyJSON`).
public struct VocabularyEntry: Codable, Sendable, Equatable, Hashable {
    /// Canonical spelling, as it should appear in transcripts.
    public var term: String
    /// Known ASR mishearings, replaced exactly (case-insensitive).
    public var soundsLike: [String]
    /// name | project | acronym | place | other — organizational metadata.
    public var category: String?
    /// Free text for humans/agents; ignored by the pipeline.
    public var notes: String?

    public init(term: String, soundsLike: [String] = [], category: String? = nil, notes: String? = nil) {
        self.term = term
        self.soundsLike = soundsLike
        self.category = category
        self.notes = notes
    }
}

/// Grounds transcripts in user-specific vocabulary (participant names, org
/// terms) three ways:
/// 1. `contextTerms(for:)` — decoder-level biasing for engines that accept
///    contextual terms (Apple SpeechTranscriber).
/// 2. Exact alias replacement — each entry's `soundsLike` mishearings.
/// 3. Fuzzy repair of near-miss words ("Sam Riviera" → "Sam Rivera") via
///    edit-distance matching.
public enum VocabularyCorrector {

    /// Discrete vocabulary terms for engines that bias on term lists
    /// (Apple SpeechTranscriber's contextual strings).
    public static func contextTerms(for entries: [VocabularyEntry]) -> [String] {
        entries
            .map { $0.term.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Full pipeline: exact alias replacement, then fuzzy near-miss repair.
    public static func correct(_ text: String, entries: [VocabularyEntry]) -> String {
        var result = text
        for entry in entries where !entry.soundsLike.isEmpty {
            let aliases = entry.soundsLike.filter { !isProtectedAlias($0) }
            guard !aliases.isEmpty else { continue }
            result = replaceAliases(in: result, aliases: aliases, with: entry.term)
        }
        return correct(result, vocabulary: entries.map(\.term))
    }

    /// True for aliases the corrector refuses to apply: a single English
    /// function word (or near-universal conversational word). Alias
    /// replacement is exact and every-occurrence, so one entry like
    /// `SIS ← "this"` (seen in a real LLM-generated vocabulary file) rewrites
    /// the entire transcript. No legitimate mishearing maps one of these to a
    /// term; multi-word aliases ("heck vat") are untouched.
    static func isProtectedAlias(_ alias: String) -> Bool {
        let words = alias.lowercased().split(separator: " ")
        return words.count == 1 && protectedAliasWords.contains(String(words[0]))
    }

    /// Aliases the corrector will ignore, for lint/UI surfacing at sync time.
    public static func ignoredAliases(in entries: [VocabularyEntry]) -> [(term: String, alias: String)] {
        entries.flatMap { entry in
            entry.soundsLike.filter(isProtectedAlias).map { (entry.term, $0) }
        }
    }

    /// English function words plus the most common conversational verbs and
    /// fillers — the words whose global replacement destroys a transcript.
    /// Deliberately NOT the full dictionary: real-word mishearings of rarer
    /// words ("cattle" → CTL, "quality" → Kuali) are the soundsLike feature's
    /// legitimate purpose and stay allowed.
    static let protectedAliasWords: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "am", "an",
        "and", "any", "are", "as", "at", "back", "be", "because", "been",
        "before", "being", "below", "between", "both", "but", "by", "can",
        "come", "could", "did", "do", "does", "doing", "down", "during",
        "each", "even", "few", "for", "from", "further", "get", "go", "going",
        "good", "got", "had", "has", "have", "having", "he", "her", "here",
        "hers", "herself", "him", "himself", "his", "how", "i", "if", "in",
        "into", "is", "it", "its", "itself", "just", "know", "like", "look",
        "make", "many", "me", "mean", "more", "most", "much", "my", "myself",
        "need", "no", "nor", "not", "now", "of", "off", "okay", "on", "once",
        "one", "only", "or", "other", "our", "ours", "ourselves", "out",
        "over", "own", "people", "really", "right", "said", "same", "say",
        "see", "she", "should", "so", "some", "still", "such", "take", "than",
        "that", "the", "their", "theirs", "them", "themselves", "then",
        "there", "these", "they", "thing", "things", "think", "this", "those",
        "through", "time", "to", "too", "two", "under", "until", "up", "very",
        "want", "was", "way", "we", "well", "were", "what", "when", "where",
        "which", "while", "who", "whom", "why", "will", "with", "work",
        "would", "yeah", "yes", "you", "your", "yours", "yourself",
        "yourselves",
    ]

    /// Replace exact (case-insensitive, whole-word) occurrences of known
    /// mishearings with the canonical term. Multi-word aliases supported.
    static func replaceAliases(in text: String, aliases: [String], with term: String) -> String {
        var tokens = tokenize(text)
        for alias in aliases {
            let aliasWords = alias.split(separator: " ").map { String($0).lowercased() }
            let n = aliasWords.count
            guard n >= 1, tokens.count >= n else { continue }
            var start = 0
            while start <= tokens.count - n {
                let window = Array(tokens[start..<(start + n)])
                let candidate = window.map { $0.core.lowercased() }
                if candidate == aliasWords, window.allSatisfy({ !$0.core.isEmpty }) {
                    tokens[start].core = term
                    tokens[start].suffix = tokens[start + n - 1].suffix
                    if n > 1 {
                        for i in (start + 1)..<(start + n) {
                            tokens[i].prefix = ""; tokens[i].core = ""; tokens[i].suffix = ""
                        }
                    }
                    start += n
                } else {
                    start += 1
                }
            }
        }
        return tokens
            .map { $0.prefix + $0.core + $0.suffix }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Replace near-misses of vocabulary terms in `text`. Multi-word terms
    /// (names) are matched as sliding windows. Conservative by design:
    /// length-scaled edit-distance budget, matching first letter, terms of at
    /// least 3 characters — and single words that spell-check as real English
    /// are never rewritten (the system dictionary as a do-not-touch list).
    public static func correct(
        _ text: String,
        vocabulary: [String]
    ) -> String {
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
            .sorted { $0.split(separator: " ").count > $1.split(separator: " ").count }
        guard !terms.isEmpty, !text.isEmpty else { return text }

        var tokens = tokenize(text)
        var consumed = [Bool](repeating: false, count: tokens.count)

        for term in terms {
            let termWords = term.split(separator: " ").map(String.init)
            let n = termWords.count
            guard n >= 1, tokens.count >= n else { continue }

            for start in 0...(tokens.count - n) {
                let window = Array(tokens[start..<(start + n)])
                guard !(start..<(start + n)).contains(where: { consumed[$0] }),
                      window.allSatisfy({ !$0.core.isEmpty }) else { continue }

                let candidate = window.map(\.core).joined(separator: " ")
                if candidate.caseInsensitiveCompare(term) == .orderedSame { break }
                guard distance(candidate.lowercased(), term.lowercased()) <= editBudget(for: term),
                      candidate.lowercased().first == term.lowercased().first else { continue }
                // Never rewrite a legitimate English word ("data" is not a
                // mishearing of "Dana"); non-words are fair game ("Corio").
                if n == 1, isKnownWord(candidate) { continue }

                // Rewrite: first token carries the whole canonical term, keeps
                // outer punctuation; middle tokens vanish; last keeps suffix.
                tokens[start].core = term
                tokens[start].suffix = tokens[start + n - 1].suffix
                if n > 1 {
                    for i in (start + 1)..<(start + n) {
                        tokens[i].prefix = ""; tokens[i].core = ""; tokens[i].suffix = ""
                    }
                }
                for i in start..<(start + n) { consumed[i] = true }
                break  // one replacement per term per turn is plenty
            }
        }

        return tokens
            .map { $0.prefix + $0.core + $0.suffix }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Internals

    struct Token {
        var prefix: String   // leading punctuation
        var core: String     // the word
        var suffix: String   // trailing punctuation
    }

    static func tokenize(_ text: String) -> [Token] {
        text.split(separator: " ", omittingEmptySubsequences: true).map { raw in
            var word = String(raw)
            var prefix = "", suffix = ""
            while let f = word.first, !f.isLetter, !f.isNumber {
                prefix.append(word.removeFirst())
            }
            while let l = word.last, !l.isLetter, !l.isNumber {
                suffix.insert(word.removeLast(), at: suffix.startIndex)
            }
            return Token(prefix: prefix, core: word, suffix: suffix)
        }
    }

    /// Allowed edit distance scales with term length.
    static func editBudget(for term: String) -> Int {
        switch term.count {
        case ..<5: return 1
        case 5..<9: return 2
        default: return 3
        }
    }

    /// True if the word is valid English on this platform. Used only as a
    /// do-not-rewrite guard, so "unknown" is the safe default.
    static func isKnownWord(_ word: String) -> Bool {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        // UITextChecker only works inside a real app context; the probe below
        // disables the gate if it degenerately accepts nonsense.
        guard Self.uiCheckerIsReliable else { return false }
        return uiCheckerKnows(word)
        #else
        return Self.systemWordList?.contains(word.lowercased()) ?? false
        #endif
    }

    #if canImport(UIKit) && !targetEnvironment(macCatalyst)
    static func uiCheckerKnows(_ word: String) -> Bool {
        let checker = UITextChecker()
        let range = NSRange(location: 0, length: word.utf16.count)
        let miss = checker.rangeOfMisspelledWord(
            in: word, range: range, startingAt: 0, wrap: false, language: "en_US")
        return miss.location == NSNotFound
    }

    /// A checker that "knows" gibberish has no loaded dictionary — ignore it.
    static let uiCheckerIsReliable: Bool = !uiCheckerKnows("xqzjvwqk")
    #else
    /// macOS: the system word list (NSSpellChecker is inert in headless
    /// processes — it accepts every string).
    static let systemWordList: Set<String>? = {
        guard let content = try? String(
            contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return nil }
        return Set(content.split(separator: "\n").map { $0.lowercased() })
    }()
    #endif

    /// Levenshtein edit distance.
    static func distance(_ a: String, _ b: String) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        let aChars = Array(a), bChars = Array(b)
        var prev = Array(0...bChars.count)
        var curr = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            curr[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
    }
}
