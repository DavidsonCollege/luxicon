import Foundation
import SpeechVAD

/// The diarization seam `MeetingPipeline` runs through.
///
/// Built on speech-swift's public result/config types so it survives library
/// upgrades. The default implementation is `ClassicDiarizationPipeline` — a
/// vendored copy of the pyannote pipeline Luxicon has always shipped, kept so
/// a speech-swift bump can't silently move speaker separation.
public protocol SpeakerDiarizer: AnyObject {
    /// Speaker-embedding model used for clustering, also used to enroll voices
    /// so enrollment embeddings live in the same space as diarized centroids.
    var embeddingModel: WeSpeakerModel { get }

    func diarize(audio: [Float], sampleRate: Int, config: DiarizationConfig) -> DiarizationResult

    /// Same as `diarize(audio:sampleRate:config:)`, reporting progress. The
    /// handler returns `false` to cancel, which yields an empty result.
    func diarize(
        audio: [Float], sampleRate: Int, config: DiarizationConfig,
        progressHandler: ((Float, String) -> Bool)?
    ) -> DiarizationResult
}

public extension SpeakerDiarizer {
    func diarize(audio: [Float], sampleRate: Int, config: DiarizationConfig) -> DiarizationResult {
        diarize(audio: audio, sampleRate: sampleRate, config: config, progressHandler: nil)
    }
}
