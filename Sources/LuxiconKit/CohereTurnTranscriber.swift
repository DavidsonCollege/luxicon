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
        let model = try await CohereTranscribeModel.load(modelId) { p in
            progress?(p, "Loading Cohere Transcribe")
        }
        return CohereTurnTranscriber(model: model, language: language)
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
