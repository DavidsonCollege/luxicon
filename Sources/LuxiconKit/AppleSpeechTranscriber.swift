import Foundation
import AVFoundation
import Speech
import AudioCommon

/// Apple's on-device long-form transcriber (Speech framework, iOS 26+).
///
/// The model is a system asset: no per-app download, and inference runs
/// out-of-process — it does not contribute to this process's memory ceiling
/// the way the CoreML/MLX engines do. Diarization still happens upstream;
/// this class only transcribes per-turn audio slices.
@available(iOS 26.0, macOS 26.0, *)
public final class AppleSpeechTranscriber: TurnTranscriber {

    public enum LoadError: Error, LocalizedError {
        case unsupportedLocale(Locale)
        case noCompatibleAudioFormat

        public var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let locale):
                return "Apple speech transcription does not support the \(locale.identifier) locale on this device."
            case .noCompatibleAudioFormat:
                return "Apple speech transcription reported no compatible audio format."
            }
        }
    }

    private let locale: Locale
    private let analyzerFormat: AVAudioFormat

    private init(locale: Locale, analyzerFormat: AVAudioFormat) {
        self.locale = locale
        self.analyzerFormat = analyzerFormat
    }

    /// Single place for the module configuration: plain transcription, no
    /// volatile/alternative reporting, no attribute decoration.
    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }

    /// Resolve the locale, install the system model asset if needed, and
    /// verify an audio format. Mirrors the other engines' `fromPretrained`
    /// contract (progress in 0...1 with a stage string).
    public static func load(
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> AppleSpeechTranscriber {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw LoadError.unsupportedLocale(.current)
        }
        let transcriber = makeTranscriber(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress?(0.1, "Downloading system speech model…")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw LoadError.noCompatibleAudioFormat
        }
        progress?(1.0, "Speech model ready")
        return AppleSpeechTranscriber(locale: locale, analyzerFormat: format)
    }

    // MARK: - TurnTranscriber

    public var supportsContext: Bool { true }

    /// Upper bound on one turn's analysis. Turns arrive pre-chunked at
    /// ≤ ~61 s of audio and Apple's transcriber runs faster than realtime,
    /// so hitting this means the analyzer session is starved or hung.
    private static let turnTimeout: TimeInterval = 180

    /// Synchronous bridge over the async SpeechAnalyzer session.
    ///
    /// Caution: this blocks a Swift-concurrency cooperative-pool thread while
    /// an unstructured `Task` on that same pool must make progress to signal —
    /// a starvation hazard the CoreML/MLX engines don't have (they block on
    /// compute that progresses on its own). The bounded wait converts a
    /// starved or hung analyzer session into a skipped (empty) turn instead
    /// of a permanent hang.
    public func transcribeTurn(
        _ audio: [Float], sampleRate: Int, context: [String]?
    ) -> TranscriptionResult {
        guard !audio.isEmpty else { return TranscriptionResult(text: "") }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = TranscriptionResult(text: "")
        let work = Task { [locale, analyzerFormat] in
            defer { semaphore.signal() }
            do {
                let text = try await Self.analyze(
                    audio: audio, sampleRate: sampleRate, locale: locale,
                    format: analyzerFormat, terms: context ?? [])
                result = TranscriptionResult(text: text)
            } catch {
                // Per-turn failure → empty text; process() skips empty turns.
                result = TranscriptionResult(text: "")
            }
        }
        guard semaphore.wait(timeout: .now() + Self.turnTimeout) == .success else {
            work.cancel()
            // Per-turn failure → empty text; process() skips empty turns.
            return TranscriptionResult(text: "")
        }
        return result
    }

    /// One analyzer session per turn: modules are cheap once the asset is
    /// installed, and a fresh session sidesteps any finalize-then-reuse
    /// ambiguity in the analyzer lifecycle.
    private static func analyze(
        audio: [Float], sampleRate: Int, locale: Locale,
        format: AVAudioFormat, terms: [String]
    ) async throws -> String {
        let transcriber = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: terms]
            try await analyzer.setContext(context)
        }

        let buffer = try pcmBuffer(from: audio, sampleRate: sampleRate, converting: format)
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        // Collect results concurrently with analysis; the sequence ends when
        // the analyzer finishes.
        async let collected: [String] = {
            var parts: [String] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if !text.isEmpty { parts.append(text) }
            }
            return parts
        }()

        _ = try await analyzer.analyzeSequence(inputSequence)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collected.joined(separator: " ")
    }

    // MARK: - Buffer conversion (testable, offline)

    /// Build a mono Float32 `AVAudioPCMBuffer` from raw samples, optionally
    /// converting to the analyzer's preferred format.
    static func pcmBuffer(
        from samples: [Float], sampleRate: Int, converting target: AVAudioFormat?
    ) throws -> AVAudioPCMBuffer {
        guard let nativeFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
            channels: 1, interleaved: false),
            let native = AVAudioPCMBuffer(
                pcmFormat: nativeFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw LoadError.noCompatibleAudioFormat
        }
        native.frameLength = AVAudioFrameCount(samples.count)
        // An empty array's buffer pointer may have a nil baseAddress; skip the
        // copy entirely rather than force-unwrap it.
        if !samples.isEmpty {
            samples.withUnsafeBufferPointer { src in
                native.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
        }
        guard let target, target != nativeFormat else { return native }

        guard let converter = AVAudioConverter(from: nativeFormat, to: target),
              let converted = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(
                    (Double(samples.count) * target.sampleRate / Double(sampleRate)).rounded(.up)))
        else {
            throw LoadError.noCompatibleAudioFormat
        }
        // AVAudioConverterInputBlock is imported as @Sendable (NS_SWIFT_SENDABLE), but
        // AVAudioConverter invokes it synchronously and serially on the calling thread
        // during this single `convert` call — never concurrently, never stored past it.
        // `nonisolated(unsafe)` on these locals reflects that call contract rather than
        // asserting general thread-safety of the captured values.
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let nativeBuffer = native
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return nativeBuffer
        }
        if let conversionError { throw conversionError }
        return converted
    }
}
