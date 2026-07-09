import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Grounds transcripts in user-specific vocabulary (participant names, org
/// terms) two ways:
/// 1. `contextString(for:)` — decoder-level biasing for engines that accept a
///    context prompt (Qwen3-ASR).
/// 2. `correct(_:vocabulary:)` — engine-agnostic post-ASR repair of near-miss
///    words ("Sam Riviera" → "Sam Rivera") via edit-distance matching.
public enum VocabularyCorrector {

    /// Context prompt handed to context-capable ASR engines.
    public static func contextString(for vocabulary: [String]) -> String? {
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return "This conversation may mention the following names and terms: "
            + terms.joined(separator: ", ") + "."
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

    /// Normalized similarity: 1 − levenshtein / max length.
    static func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return 1.0 - Double(distance(a, b)) / Double(max(a.count, b.count))
    }

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
