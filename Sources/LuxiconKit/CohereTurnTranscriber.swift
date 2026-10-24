#if os(macOS)
import Foundation
import AudioCommon
import CohereTranscribeASR

/// Cohere Transcribe 03-2026 (2B encoder-decoder, MLX/Metal, INT5) as a
/// per-turn engine. macOS only: the package links `CohereTranscribeASR` for
/// macOS alone, and peak memory (~4 GB) is out of reach on iPhone.
///
/// The model downloads ~1.6 GB from Hugging Face on first load. Decoding is
/// greedy with a fixed prompt; there is no context/vocabulary biasing hook,
/// so vocabulary grounding happens post-ASR like Parakeet.
public final class CohereTurnTranscriber: TurnTranscriber {
    public let model: CohereTranscribeModel
    public let language: String

    public init(model: CohereTranscribeModel, language: String = "en") {
        self.model = model
        self.language = language
    }

    /// Download (first run) and load the INT5 model. `modelId` may be a
    /// Hugging Face repo id or a local directory.
    public static func load(
        modelId: String = CohereTranscribeModel.defaultModelId,
        language: String = "en",
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> CohereTurnTranscriber {
        // The downloader reports bytes only; loading the weights afterwards
        // takes seconds with no callbacks, so the stage text must say so
        // rather than sit at "100%". Concurrent ranged chunks can also report
        // out of order — show the high-water mark.
        let highWater = HighWaterMark()
        progress?(0, loadStage(fraction: 0, downloading: false))
        let model = try await CohereTranscribeModel.load(modelId) { p in
            let shown = highWater.raise(to: p)
            progress?(shown, loadStage(fraction: shown, downloading: shown < 1))
        }
        return CohereTurnTranscriber(model: model, language: language)
    }

    /// Stage text for a load: "Downloading Cohere model… NN%" while bytes
    /// arrive, then "Loading Cohere model…" (no percentage) while the
    /// weights load from disk.
    static func loadStage(fraction: Double, downloading: Bool) -> String {
        guard downloading else { return "Loading Cohere model…" }
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        return "Downloading Cohere model… \(percent)%"
    }

    /// Monotonic max of reported fractions, safe across callback threads.
    private final class HighWaterMark: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0
        func raise(to fraction: Double) -> Double {
            lock.lock(); defer { lock.unlock() }
            value = max(value, fraction)
            return value
        }
    }

    public var supportsContext: Bool { false }

    public func transcribeTurn(_ audio: [Float], sampleRate: Int, context: [String]?) -> TranscriptionResult {
        let text = model.transcribe(audio: audio, sampleRate: sampleRate, language: language)
        // No per-token confidence is exposed; report a neutral value.
        return TranscriptionResult(text: text, language: language, confidence: 1.0)
    }

    /// Cohere invents a stock closer ("Thank you.") on near-silent short
    /// turns. Judged on the diarized span, not the padded ASR slice.
    public func filterTurnText(_ text: String, turnDuration: Double) -> String {
        ShortTurnGuard.filter(text, duration: turnDuration)
    }
}
#endif
