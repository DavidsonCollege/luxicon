// Copyright 2025 Ivan Digital
// Licensed under the Apache License, Version 2.0. You may obtain a copy of
// the License at http://www.apache.org/licenses/LICENSE-2.0 (full text in
// THIRD-PARTY-NOTICES.md). Distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND.
//
// Vendored from soniqo/speech-swift @ e403d0b (Apache-2.0)
// Source: Sources/SpeechVAD/DiarizationPipeline.swift (PyannoteDiarizationPipeline)
// Modified by Luxicon: renamed ClassicDiarizationPipeline and conformed to
// SpeakerDiarizer; `fromPretrained` replaced by `load(progress:)` with the
// model IDs fixed; the unused Silero VAD pre-filter, extractSpeaker and
// trimToSpeechMask removed (Luxicon never enabled the filter, so the
// remaining path is the one it always ran); DiarizationConfig,
// DiarizationResult, DiarizedSegment and WeSpeakerModel stay the library's
// public types. Segmentation, embedding and clustering logic unchanged.

import Foundation
import MLX
import AudioCommon
import SpeechVAD

/// Errors from loading the classic diarization models.
public enum ClassicDiarizationError: Error, LocalizedError {
    case noWeightsFound(URL)

    public var errorDescription: String? {
        switch self {
        case .noWeightsFound(let dir):
            return "No segmentation model weights found in \(dir.path)"
        }
    }
}

/// Pyannote-based speaker diarization: segmentation + per-window embedding +
/// constrained clustering. This is the pipeline Luxicon has always shipped
/// (speech-swift `PyannoteDiarizationPipeline` @ e403d0b), vendored so the
/// library can be upgraded without moving speaker separation.
///
/// - Warning: Not thread-safe. Create separate instances for concurrent use.
///
/// 1. **Segmentation**: Pyannote on 10s sliding windows (50% overlap) → per-speaker probability tracks
/// 2. **Per-window Embedding**: WeSpeaker 256-dim embedding per local speaker from non-overlapping speech
/// 3. **Constrained Clustering**: Agglomerative clustering with same-window constraint → global speaker IDs
public final class ClassicDiarizationPipeline: SpeakerDiarizer {

    /// Hugging Face repo of the MLX pyannote segmentation-3.0 weights.
    public static let segmentationModelId = "aufklarer/Pyannote-Segmentation-MLX"
    /// Hugging Face repo of the MLX WeSpeaker ResNet34-LM weights.
    public static let embeddingModelId = "aufklarer/WeSpeaker-ResNet34-LM-MLX"

    /// Pyannote segmentation model
    let segmentationModel: ClassicSegmentationModel

    /// Segmentation config
    let segConfig: ClassicSegmentationConfig

    /// WeSpeaker embedding model
    public let embeddingModel: WeSpeakerModel

    init(
        segmentationModel: ClassicSegmentationModel,
        segConfig: ClassicSegmentationConfig,
        embeddingModel: WeSpeakerModel
    ) {
        self.segmentationModel = segmentationModel
        self.segConfig = segConfig
        self.embeddingModel = embeddingModel
    }

    /// Download (first run) and load the segmentation and embedding models.
    ///
    /// Same weights, cache locations and progress fractions as the library's
    /// `PyannoteDiarizationPipeline.fromPretrained()` with default arguments.
    public static func load(
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ClassicDiarizationPipeline {
        progress?(0.0, "Downloading segmentation model...")

        let segCacheDir = try HuggingFaceDownloader.getCacheDirectory(for: segmentationModelId)
        try await HuggingFaceDownloader.downloadWeights(
            modelId: segmentationModelId,
            to: segCacheDir,
            progressHandler: { p in
                progress?(p * 0.3, "Downloading segmentation weights...")
            }
        )

        let segConfig = ClassicSegmentationConfig.default
        let segModel = ClassicSegmentationModel(config: segConfig)
        try ClassicSegmentationWeightLoader.loadWeights(model: segModel, from: segCacheDir)

        progress?(0.3, "Downloading speaker embedding model...")

        let embModel = try await WeSpeakerModel.fromPretrained(
            modelId: embeddingModelId,
            engine: .mlx,
            progressHandler: { p, status in
                progress?(0.3 + p * 0.4, status)
            }
        )

        progress?(1.0, "Ready")

        return ClassicDiarizationPipeline(
            segmentationModel: segModel,
            segConfig: segConfig,
            embeddingModel: embModel
        )
    }

    /// Run speaker diarization on audio.
    public func diarize(
        audio: [Float],
        sampleRate: Int,
        config: DiarizationConfig = .default
    ) -> DiarizationResult {
        diarize(audio: audio, sampleRate: sampleRate, config: config, progressHandler: nil)
    }

    /// Diarize audio with progress reporting and optional cancellation.
    ///
    /// Reports progress during the two most expensive stages (segmentation and
    /// embedding extraction). The handler returns `true` to continue, `false`
    /// to cancel; when cancelled, an empty `DiarizationResult` is returned.
    public func diarize(
        audio: [Float],
        sampleRate: Int,
        config: DiarizationConfig = .default,
        progressHandler: ((Float, String) -> Bool)?
    ) -> DiarizationResult {
        let samples = ClassicDiarizationHelpers.resample(audio, from: sampleRate, to: segConfig.sampleRate)
        return runEmbeddingClusteredDiarization(
            samples: samples, config: config, progressHandler: progressHandler)
    }

    // MARK: - Embedding-Clustered Diarization

    /// Per-window raw probability tracks (3 speakers × nFrames).
    private struct WindowProbs {
        let startSample: Int
        let endSample: Int
        /// Speaker probability tracks [3][nFrames]
        let tracks: [[Float]]
    }

    /// Per-window per-speaker embedding for clustering.
    private struct WindowSpeakerEmbedding {
        let windowIndex: Int
        let localSpeakerId: Int
        let embedding: [Float]
    }

    /// Run diarization using per-window speaker embeddings + constrained agglomerative clustering.
    ///
    /// 1. Segment all windows → per-speaker probability tracks
    /// 2. Extract per-window per-speaker embeddings from non-overlapping speech
    /// 3. Constrained clustering (same-window items never merge) → global speaker IDs
    /// 4. Map cluster IDs back to binarized segments
    private func runEmbeddingClusteredDiarization(
        samples: [Float],
        config: DiarizationConfig,
        progressHandler: ((Float, String) -> Bool)? = nil
    ) -> DiarizationResult {
        let windowDuration: Float = 10.0
        let sampleRate = segConfig.sampleRate
        let windowSamples = Int(windowDuration * Float(sampleRate))
        let framesPerChunk = 589
        let frameDuration = windowDuration / Float(framesPerChunk)
        let stepSamples = windowSamples / 2  // 50% overlap

        let numSamples = samples.count
        guard numSamples > 0 else {
            return DiarizationResult(segments: [], numSpeakers: 0, speakerEmbeddings: [])
        }

        // Generate window positions with 50% overlap
        var positions = [(start: Int, end: Int)]()
        if numSamples <= windowSamples {
            positions.append((0, numSamples))
        } else {
            var start = 0
            while start + windowSamples <= numSamples {
                positions.append((start, start + windowSamples))
                start += stepSamples
            }
            if positions.isEmpty || positions.last!.end < numSamples {
                positions.append((numSamples - windowSamples, numSamples))
            }
        }

        // Step 1: Run segmentation on all windows, collect probability tracks
        // Progress: both steps iterate over all windows, so total = 2 * windowCount
        let totalUnits = positions.count * 2
        var completedUnits = 0
        var windowProbs = [WindowProbs]()

        let emptyResult = DiarizationResult(segments: [], numSpeakers: 0, speakerEmbeddings: [])

        // Windows are batched through the segmentation model: the BiLSTM runs
        // ~600 sequential timesteps of tiny ops per window, so per-op dispatch
        // overhead dominates a batch-of-1 forward pass. Stacking windows on the
        // batch axis amortizes it (measured ~5x on the segmentation stage).
        let segmentationBatch = 8
        var batchStart = 0
        while batchStart < positions.count {
            let batchEnd = min(batchStart + segmentationBatch, positions.count)
            if progressHandler?(Float(completedUnits) / Float(totalUnits), "Segmenting \(batchStart + 1)/\(positions.count)") == false {
                return emptyResult
            }

            var flat = [Float]()
            flat.reserveCapacity((batchEnd - batchStart) * windowSamples)
            for p in batchStart..<batchEnd {
                let (start, end) = positions[p]
                flat.append(contentsOf: samples[start..<end])
                if end - start < windowSamples {
                    flat.append(contentsOf: [Float](repeating: 0, count: windowSamples - (end - start)))
                }
            }

            let input = MLXArray(flat).reshaped(batchEnd - batchStart, 1, windowSamples)
            let posteriors = segmentationModel(input)
            let speakerProbs = ClassicPowersetDecoder.speakerProbabilities(from: posteriors)
            eval(speakerProbs)

            for (bi, p) in (batchStart..<batchEnd).enumerated() {
                var tracks = [[Float]]()
                for spk in 0..<3 {
                    tracks.append(speakerProbs[bi, 0..., spk].asArray(Float.self))
                }
                windowProbs.append(WindowProbs(startSample: positions[p].start,
                                               endSample: positions[p].end, tracks: tracks))
            }
            completedUnits += batchEnd - batchStart
            batchStart = batchEnd
        }

        guard !windowProbs.isEmpty else {
            return DiarizationResult(segments: [], numSpeakers: 0, speakerEmbeddings: [])
        }

        // Step 2: Extract per-window per-speaker embeddings from non-overlapping speech
        let minEmbeddingSamples = sampleRate / 2  // 0.5s minimum for embedding
        var windowEmbeddings = [WindowSpeakerEmbedding]()

        for (wIdx, wp) in windowProbs.enumerated() {
            completedUnits += 1
            if progressHandler?(Float(completedUnits) / Float(totalUnits), "Embedding \(wIdx + 1)/\(windowProbs.count)") == false {
                return emptyResult
            }

            let windowStartSample = wp.startSample

            for localSpk in 0..<3 {
                let probs = wp.tracks[localSpk]

                // Binarize this speaker's track
                let binarySegments = ClassicPowersetDecoder.binarize(
                    probs: probs, onset: config.onset,
                    offset: config.offset, frameDuration: frameDuration)

                guard !binarySegments.isEmpty else { continue }

                // Collect audio from frames where ONLY this speaker is active (non-overlapping)
                var spkAudio = [Float]()

                for seg in binarySegments {
                    let segStartFrame = Int(seg.startTime / frameDuration)
                    let segEndFrame = min(Int(seg.endTime / frameDuration), probs.count)

                    for frame in segStartFrame..<segEndFrame {
                        // Check if other speakers are below offset at this frame
                        var otherActive = false
                        for otherSpk in 0..<3 where otherSpk != localSpk {
                            if wp.tracks[otherSpk][frame] >= config.offset {
                                otherActive = true
                                break
                            }
                        }
                        if otherActive { continue }

                        // Extract audio samples for this frame
                        let frameStartSample = windowStartSample + Int(Float(frame) * frameDuration * Float(sampleRate))
                        let frameEndSample = min(
                            windowStartSample + Int(Float(frame + 1) * frameDuration * Float(sampleRate)),
                            samples.count
                        )
                        if frameEndSample > frameStartSample {
                            spkAudio.append(contentsOf: samples[frameStartSample..<frameEndSample])
                        }
                    }
                }

                // Need minimum 0.5s of audio for a reliable embedding
                guard spkAudio.count >= minEmbeddingSamples else { continue }

                let embedding = embeddingModel.embed(audio: spkAudio, sampleRate: sampleRate)
                windowEmbeddings.append(WindowSpeakerEmbedding(
                    windowIndex: wIdx, localSpeakerId: localSpk, embedding: embedding))
            }
        }

        // Handle edge case: no embeddings could be extracted
        guard !windowEmbeddings.isEmpty else {
            return DiarizationResult(segments: [], numSpeakers: 0, speakerEmbeddings: [])
        }

        // Step 3: Constrained agglomerative clustering
        let clusterItems = windowEmbeddings.map {
            ClassicDiarizationHelpers.ClusterItem(
                windowIndex: $0.windowIndex,
                localSpeakerId: $0.localSpeakerId,
                embedding: $0.embedding)
        }

        let (clusterAssignment, centroids) = ClassicDiarizationHelpers.constrainedAgglomerativeClustering(
            items: clusterItems, threshold: config.clusteringThreshold)

        // Build mapping: (windowIndex, localSpeakerId) → global cluster ID
        var localToGlobal = [Int: [Int: Int]]()  // windowIndex → (localSpeakerId → globalId)
        for (i, we) in windowEmbeddings.enumerated() {
            localToGlobal[we.windowIndex, default: [:]][we.localSpeakerId] = clusterAssignment[i]
        }

        // Step 4: Build segments with global speaker IDs
        var diarizedSegments = [DiarizedSegment]()

        for (w, wp) in windowProbs.enumerated() {
            let windowStartTime = Float(wp.startSample) / Float(sampleRate)
            let windowEndTime = Float(wp.endSample) / Float(sampleRate)

            // Center zone ownership (same as before)
            let prevEnd = w > 0 ?
                Float(positions[w - 1].end) / Float(sampleRate) : 0
            let nextStart = w + 1 < positions.count ?
                Float(positions[w + 1].start) / Float(sampleRate) : Float(numSamples) / Float(sampleRate)
            let ownStart = w > 0 ? (windowStartTime + prevEnd) / 2 : 0
            let ownEnd = w + 1 < positions.count ?
                (windowEndTime + nextStart) / 2 : Float(numSamples) / Float(sampleRate)

            for localSpk in 0..<3 {
                guard let globalSpk = localToGlobal[w]?[localSpk] else {
                    continue  // No embedding for this speaker — skip (insufficient audio)
                }

                let probs = wp.tracks[localSpk]
                let segments = ClassicPowersetDecoder.binarize(
                    probs: probs, onset: config.onset,
                    offset: config.offset, frameDuration: frameDuration)

                for seg in segments {
                    let absStart = windowStartTime + seg.startTime
                    let absEnd = min(windowStartTime + seg.endTime, windowEndTime)

                    // Clip to center zone
                    let clippedStart = max(absStart, ownStart)
                    let clippedEnd = min(absEnd, ownEnd)
                    guard clippedEnd - clippedStart >= config.minSpeechDuration else { continue }

                    diarizedSegments.append(DiarizedSegment(
                        startTime: clippedStart,
                        endTime: clippedEnd,
                        speakerId: globalSpk
                    ))
                }
            }
        }

        diarizedSegments.sort { $0.startTime < $1.startTime }

        // Compact speaker IDs and merge
        diarizedSegments = ClassicDiarizationHelpers.compactSpeakerIds(diarizedSegments)
        let merged = ClassicDiarizationHelpers.mergeSegments(
            diarizedSegments, minSilence: config.minSilenceDuration)
        let numSpeakers = Set(merged.map(\.speakerId)).count

        // Re-compact centroids to match compacted speaker IDs
        let finalCentroids: [[Float]]
        if numSpeakers <= centroids.count {
            finalCentroids = Array(centroids.prefix(numSpeakers))
        } else {
            // Pad with zero embeddings for speakers that had no embedding
            var padded = centroids
            while padded.count < numSpeakers {
                padded.append([Float](repeating: 0, count: 256))
            }
            finalCentroids = padded
        }

        return DiarizationResult(
            segments: merged,
            numSpeakers: numSpeakers,
            speakerEmbeddings: finalCentroids
        )
    }
}
