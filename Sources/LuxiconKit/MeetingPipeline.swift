import Foundation
import AudioCommon
import MLX
import SpeechVAD
import ParakeetASR

/// One speaker turn's worth of transcription, engine-agnostic.
public protocol TurnTranscriber: AnyObject {
    /// Whether `context` is honored (decoder-level vocabulary biasing).
    var supportsContext: Bool { get }
    func transcribeTurn(_ audio: [Float], sampleRate: Int, context: [String]?) -> TranscriptionResult
}

/// Parakeet TDT (CoreML, Neural Engine). Fast and battery-friendly; no
/// context biasing — vocabulary grounding happens post-ASR.
extension ParakeetASRModel: TurnTranscriber {
    public var supportsContext: Bool { false }
    public func transcribeTurn(_ audio: [Float], sampleRate: Int, context: [String]?) -> TranscriptionResult {
        transcribeWithLanguage(audio: audio, sampleRate: sampleRate, language: nil)
    }
}

/// Which ASR engine transcribes speaker turns. The app persists the choice
/// in store.json, and CLI flags pass it as a raw value — both seams demand
/// stable, backward-compatible cases.
public enum ASREngine: String, Codable, Sendable {
    /// Parakeet TDT — CoreML/ANE, fast, the pre-iOS-26 default.
    case parakeet
    /// Apple SpeechTranscriber — system model, out-of-process, iOS 26+.
    case appleSpeech

    /// Tolerant decode: an engine persisted by an older build (e.g. the
    /// retired "qwen3") falls back to the default instead of failing the
    /// entire store.json decode and taking the user's library with it.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ASREngine(rawValue: raw) ?? .parakeet
    }

    /// Default engine for this device: Apple's system transcriber where the
    /// OS supports it, otherwise Parakeet. Locale/asset failures surface at
    /// load time and fall back there — this is only the cheap OS gate.
    public static func resolvedDefault() -> ASREngine {
        if #available(iOS 26.0, macOS 26.0, *) {
            return resolvedDefault(appleSpeechAvailable: true)
        }
        return resolvedDefault(appleSpeechAvailable: false)
    }

    /// Testable seam for `resolvedDefault()`.
    public static func resolvedDefault(appleSpeechAvailable: Bool) -> ASREngine {
        appleSpeechAvailable ? .appleSpeech : .parakeet
    }
}

/// Load-time engine failure; the app catches it to fall back to Parakeet.
public struct EngineUnavailableError: Error, LocalizedError {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// End-to-end 1-on-1 processing: diarize → per-turn transcription → speaker naming.
///
/// All inference is synchronous and CPU/GPU/ANE-bound; call `process` from a
/// background task. The class is not thread-safe — use one instance per task.
public final class MeetingPipeline {
    public let diarizer: PyannoteDiarizationPipeline
    public let asr: any TurnTranscriber

    /// Sample rate `process` expects. Load or record audio at this rate.
    public static let sampleRate = 16000

    /// Ceiling for MLX's freed-buffer cache while `process` runs. Large enough
    /// to reuse buffers within a window batch, small enough that a long
    /// recording's parade of unique tensor shapes can't accumulate gigabytes.
    static let gpuCacheLimit = 512 * 1024 * 1024

    public struct Options: Sendable {
        /// Hard cap on distinct speakers; extra diarized speakers are folded
        /// into the nearest kept speaker by embedding similarity. 1-on-1s → 2.
        public var maxSpeakers: Int
        /// Merge consecutive same-speaker segments separated by less than this many seconds.
        public var turnMergeGap: Double
        /// Padding in seconds added around each turn before transcription.
        public var asrPadding: Double
        /// Minimum cosine similarity for an enrollment to claim a speaker.
        public var enrollmentThreshold: Float
        /// Diarization thresholds passed through to the engine.
        public var diarization: DiarizationConfig

        public init(
            maxSpeakers: Int = 2,
            turnMergeGap: Double = 1.0,
            asrPadding: Double = 0.15,
            enrollmentThreshold: Float = 0.35,
            diarization: DiarizationConfig = .default
        ) {
            self.maxSpeakers = maxSpeakers
            self.turnMergeGap = turnMergeGap
            self.asrPadding = asrPadding
            self.enrollmentThreshold = enrollmentThreshold
            self.diarization = diarization
        }

        public static let oneOnOne = Options()
    }

    public init(diarizer: PyannoteDiarizationPipeline, asr: any TurnTranscriber) {
        self.diarizer = diarizer
        self.asr = asr
    }

    /// Download (first run) and load both models.
    public static func load(
        engine: ASREngine = .parakeet,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> MeetingPipeline {
        let diarizer = try await DiarizationPipeline.fromPretrained(progressHandler: { p, stage in
            progress?(p * 0.5, stage)
        })
        let asr: any TurnTranscriber
        switch engine {
        case .parakeet:
            asr = try await ParakeetASRModel.fromPretrained(progressHandler: { p, stage in
                progress?(0.5 + p * 0.5, stage)
            })
        case .appleSpeech:
            guard #available(iOS 26.0, macOS 26.0, *) else {
                throw EngineUnavailableError(
                    reason: "Apple speech transcription requires iOS 26 or macOS 26")
            }
            asr = try await AppleSpeechTranscriber.load { p, stage in
                progress?(0.5 + p * 0.5, stage)
            }
        }
        return MeetingPipeline(diarizer: diarizer, asr: asr)
    }

    /// Extract a speaker embedding from ~10s of one person talking.
    public func embedVoice(audio: [Float], sampleRate: Int = MeetingPipeline.sampleRate) -> [Float] {
        diarizer.embeddingModel.embed(audio: audio, sampleRate: sampleRate)
    }

    /// Process a full recording into a labeled transcript.
    ///
    /// - Parameters:
    ///   - audio: mono Float32 PCM at `MeetingPipeline.sampleRate`
    ///   - enrollments: known voices to auto-label speakers
    ///   - vocabulary: names/terms likely to occur (participants, org jargon).
    ///     Injected as decoder context on context-capable engines, and applied
    ///     as a post-ASR near-miss correction on every engine.
    ///   - progress: (0–1, stage description); checked between turns for Task cancellation
    public func process(
        audio: [Float],
        title: String,
        date: Date,
        enrollments: [VoiceEnrollment] = [],
        vocabulary: [VocabularyEntry] = [],
        options: Options = .oneOnOne,
        progress: ((Double, String) -> Void)? = nil
    ) throws -> MeetingTranscript {
        let sr = Self.sampleRate
        let duration = Double(audio.count) / Double(sr)

        // MLX keeps every freed GPU buffer in a cache, and diarization runs
        // ~3 embedding forward passes per 10 s window, each with a unique
        // input length — so on long recordings the cache only ever grows
        // (a 45-minute meeting reached iOS's ~6 GB per-process limit and was
        // jetsam-killed). Cap the cache for the run and drop it afterwards.
        MLX.Memory.cacheLimit = min(MLX.Memory.cacheLimit, Self.gpuCacheLimit)
        defer { MLX.Memory.clearCache() }

        // 1. Diarize (≈ first 60% of the work)
        var result = diarizer.diarize(audio: audio, sampleRate: sr, config: options.diarization) { p, stage in
            progress?(Double(p) * 0.6, stage)
            return !Task.isCancelled
        }
        try Task.checkCancellation()

        // 2. Fold surplus speakers into the dominant ones
        result = Self.capSpeakers(result, to: options.maxSpeakers)

        // 3. Group segments into turns
        let turnSpans = Self.buildTurns(segments: result.segments, mergeGap: options.turnMergeGap)

        // 4. Transcribe each turn
        let context = asr.supportsContext ? VocabularyCorrector.contextTerms(for: vocabulary) : nil
        var turns: [TranscriptTurn] = []
        turns.reserveCapacity(turnSpans.count)
        for (i, span) in turnSpans.enumerated() {
            try Task.checkCancellation()
            progress?(0.6 + 0.4 * Double(i) / Double(max(turnSpans.count, 1)),
                      "Transcribing turn \(i + 1)/\(turnSpans.count)")
            let lo = max(0, Int((span.start - options.asrPadding) * Double(sr)))
            let hi = min(audio.count, Int((span.end + options.asrPadding) * Double(sr)))
            guard hi > lo else { continue }
            let slice = Array(audio[lo..<hi])
            let asrResult = Self.transcribeBounded(slice, asr: asr, sampleRate: sr, context: context)
            var text = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = VocabularyCorrector.correct(text, entries: vocabulary)
            guard !text.isEmpty else { continue }
            turns.append(TranscriptTurn(
                id: turns.count,
                speakerId: span.speakerId,
                start: span.start,
                end: span.end,
                text: text,
                confidence: asrResult.confidence
            ))
        }

        // 5. Name speakers from enrollments
        var transcript = MeetingTranscript(title: title, date: date, duration: duration, turns: turns)
        for (speakerId, name) in Self.matchEnrollments(
            centroids: result.speakerEmbeddings,
            enrollments: enrollments,
            threshold: options.enrollmentThreshold
        ) {
            transcript.setName(name, forSpeaker: speakerId)
        }
        progress?(1.0, "Done")
        return transcript
    }

    // MARK: - Bounded transcription

    /// Longest audio span fed to the ASR engine in one call; bounds the
    /// autorelease accumulation per pool drain in `transcribeBounded`.
    static let maxASRChunkSeconds: TimeInterval = 60

    /// Split `sampleCount` samples into consecutive chunks of at most
    /// `maxSeconds`. A sub-second tail is folded into the previous chunk —
    /// it can't carry a word, and some engines choke on near-empty input —
    /// so the last chunk may slightly exceed `maxSeconds` by design.
    static func chunkRanges(sampleCount: Int, sampleRate: Int, maxSeconds: TimeInterval) -> [Range<Int>] {
        guard sampleCount > 0 else { return [] }
        let maxLen = max(1, Int(maxSeconds * Double(sampleRate)))
        guard sampleCount > maxLen else { return [0..<sampleCount] }
        var ranges: [Range<Int>] = []
        var start = 0
        while start < sampleCount {
            let end = min(start + maxLen, sampleCount)
            ranges.append(start..<end)
            start = end
        }
        if let last = ranges.last, ranges.count > 1, last.count < sampleRate {
            ranges.removeLast()
            let previous = ranges.removeLast()
            ranges.append(previous.lowerBound..<last.upperBound)
        }
        return ranges
    }

    /// Run the ASR engine over one turn's audio in bounded chunks, each
    /// inside its own autoreleasepool.
    ///
    /// CoreML predictions autorelease their output buffers, and `process`
    /// runs synchronously on one thread with no suspension points — nothing
    /// drains until the whole meeting is done. On a 45-minute recording that
    /// accumulated ANE-backed buffers from hundreds of thousands of decoder
    /// predictions until CoreML's E5 runtime failed to bind one and raised an
    /// uncatchable NSException (MLE5BindEmptyMemoryObjectToPort → SIGABRT).
    /// Draining per chunk keeps the pool bounded regardless of turn length.
    static func transcribeBounded(
        _ samples: [Float], asr: any TurnTranscriber, sampleRate: Int, context: [String]?
    ) -> TranscriptionResult {
        let ranges = chunkRanges(
            sampleCount: samples.count, sampleRate: sampleRate, maxSeconds: maxASRChunkSeconds)
        if ranges.count <= 1 {
            return autoreleasepool { asr.transcribeTurn(samples, sampleRate: sampleRate, context: context) }
        }
        var texts: [String] = []
        var confidenceSum: Float = 0
        var confidenceWeight = 0
        for range in ranges {
            let piece = autoreleasepool {
                asr.transcribeTurn(Array(samples[range]), sampleRate: sampleRate, context: context)
            }
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            texts.append(text)
            confidenceSum += piece.confidence * Float(range.count)
            confidenceWeight += range.count
        }
        return TranscriptionResult(
            text: texts.joined(separator: " "),
            confidence: confidenceWeight > 0 ? confidenceSum / Float(confidenceWeight) : 0
        )
    }

    // MARK: - Steps (internal, unit-testable)

    struct TurnSpan: Equatable {
        var speakerId: Int
        var start: Double
        var end: Double
    }

    /// Merge consecutive same-speaker segments with small gaps into speaker turns.
    static func buildTurns(segments: [DiarizedSegment], mergeGap: Double) -> [TurnSpan] {
        let sorted = segments.sorted { $0.startTime < $1.startTime }
        var turns: [TurnSpan] = []
        for seg in sorted {
            if var last = turns.last,
               last.speakerId == seg.speakerId,
               Double(seg.startTime) - last.end <= mergeGap {
                last.end = max(last.end, Double(seg.endTime))
                turns[turns.count - 1] = last
            } else {
                turns.append(TurnSpan(
                    speakerId: seg.speakerId,
                    start: Double(seg.startTime),
                    end: Double(seg.endTime)
                ))
            }
        }
        return turns
    }

    /// Keep the `max` speakers with the most talk time; reassign the rest to the
    /// nearest kept centroid (or drop their segments if no embeddings exist).
    static func capSpeakers(_ result: DiarizationResult, to max: Int) -> DiarizationResult {
        guard result.numSpeakers > max, max > 0 else { return result }

        var talkTime: [Int: Float] = [:]
        for seg in result.segments {
            talkTime[seg.speakerId, default: 0] += seg.duration
        }
        let kept = talkTime.sorted { $0.value > $1.value }.prefix(max).map(\.key)
        let keptSet = Set(kept)

        // Map dropped speaker → nearest kept speaker by centroid cosine similarity.
        var remap: [Int: Int] = [:]
        for dropped in talkTime.keys where !keptSet.contains(dropped) {
            guard result.speakerEmbeddings.indices.contains(dropped) else { continue }
            let emb = result.speakerEmbeddings[dropped]
            let nearest = kept.max { a, b in
                cosineSimilarity(emb, result.speakerEmbeddings[a])
                    < cosineSimilarity(emb, result.speakerEmbeddings[b])
            }
            if let nearest { remap[dropped] = nearest }
        }

        // Renumber kept speakers 0..<max preserving embedding order.
        let renumber = Dictionary(uniqueKeysWithValues: kept.sorted().enumerated().map { ($1, $0) })
        let segments = result.segments.compactMap { seg -> DiarizedSegment? in
            let target = keptSet.contains(seg.speakerId) ? seg.speakerId : remap[seg.speakerId]
            guard let target, let newId = renumber[target] else { return nil }
            return DiarizedSegment(startTime: seg.startTime, endTime: seg.endTime, speakerId: newId)
        }
        let embeddings = kept.sorted().compactMap { id in
            result.speakerEmbeddings.indices.contains(id) ? result.speakerEmbeddings[id] : nil
        }
        return DiarizationResult(segments: segments, numSpeakers: keptSet.count, speakerEmbeddings: embeddings)
    }

    /// Greedy best-first assignment of enrollments to speaker centroids.
    /// Each enrollment and each speaker is used at most once.
    static func matchEnrollments(
        centroids: [[Float]],
        enrollments: [VoiceEnrollment],
        threshold: Float
    ) -> [(speakerId: Int, name: String)] {
        var candidates: [(sim: Float, speakerId: Int, name: String)] = []
        for (speakerId, centroid) in centroids.enumerated() {
            for enrollment in enrollments {
                let sim = cosineSimilarity(centroid, enrollment.embedding)
                if sim >= threshold {
                    candidates.append((sim, speakerId, enrollment.name))
                }
            }
        }
        var usedSpeakers = Set<Int>()
        var usedNames = Set<String>()
        var matches: [(speakerId: Int, name: String)] = []
        for c in candidates.sorted(by: { $0.sim > $1.sim }) {
            guard !usedSpeakers.contains(c.speakerId), !usedNames.contains(c.name) else { continue }
            usedSpeakers.insert(c.speakerId)
            usedNames.insert(c.name)
            matches.append((c.speakerId, c.name))
        }
        return matches
    }
}
