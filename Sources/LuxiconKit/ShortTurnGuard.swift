import Foundation

/// Drops a stock closer the ASR engine invented for a very short turn.
///
/// Encoder-decoder models (Cohere Transcribe) fill near-silent audio with
/// the most likely sentence from their training data — on a 0.95 s turn of
/// breath or a cough, that came out as "Thank you." A real short answer
/// ("Okay.", "Yeah.") is left alone: only an exact stock closer on a turn
/// shorter than `maxDuration` is emptied. Applied to Cohere turns only (via
/// `TurnTranscriber.filterTurnText`); Parakeet and Apple Speech don't do this.
public enum ShortTurnGuard {
    /// Turns at least this long (seconds, diarized span) are never filtered.
    public static let maxDuration = 1.0
    /// Exact outputs treated as hallucinations on a short turn.
    public static let stockClosers: Set<String> = [
        "Thank you.", "Thanks.", "Thank you very much.", "Bye.",
    ]

    /// `text` with a hallucinated closer removed: empty when the turn is
    /// shorter than `maxDuration` and the trimmed text is exactly a stock
    /// closer, otherwise `text` unchanged.
    public static func filter(_ text: String, duration: Double) -> String {
        guard duration < maxDuration else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return stockClosers.contains(trimmed) ? "" : text
    }
}
