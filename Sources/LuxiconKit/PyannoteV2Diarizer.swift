import Foundation
import SpeechVAD

/// Adapts speech-swift's `PyannoteDiarizationPipeline` (the v2 pipeline) to
/// the `SpeakerDiarizer` seam.
///
/// The clustering threshold is applied here, overriding whatever
/// `DiarizationConfig.clusteringThreshold` the caller passes (the pipeline
/// options carry the classic 0.715 default).
///
/// Threshold semantics: the library merges clusters while their distance is
/// BELOW the threshold, so a LOWER value means FEWER merges (more speakers)
/// and a higher one means more merging. Upstream's doc comment ("lower = more
/// merges") is backwards.
public final class PyannoteV2Diarizer: SpeakerDiarizer {
    private let pipeline: PyannoteDiarizationPipeline
    public let threshold: Float

    public var embeddingModel: WeSpeakerModel { pipeline.embeddingModel }

    init(pipeline: PyannoteDiarizationPipeline, threshold: Float) {
        self.pipeline = pipeline
        self.threshold = threshold
    }

    public static func load(
        threshold: Float,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> PyannoteV2Diarizer {
        let pipeline = try await PyannoteDiarizationPipeline.fromPretrained(
            progressHandler: progress.map { p in { v, s in p(v, s) } })
        return PyannoteV2Diarizer(pipeline: pipeline, threshold: threshold)
    }

    public func diarize(
        audio: [Float], sampleRate: Int, config: DiarizationConfig,
        progressHandler: ((Float, String) -> Bool)?
    ) -> DiarizationResult {
        var config = config
        config.clusteringThreshold = threshold
        return pipeline.diarize(
            audio: audio, sampleRate: sampleRate, config: config,
            progressHandler: progressHandler)
    }
}
