import Foundation
import AVFoundation
import LuxiconKit

/// Captures microphone audio as 16 kHz mono Float32 (the pipeline's input format).
///
/// When started with a URL, samples are also streamed to disk as they arrive,
/// so a crash mid-recording loses at most the last audio chunk — the file is
/// recoverable via `WAVFile.repairHeader`. Sample accumulation happens on the
/// audio render thread behind a lock; UI reads `level`/`duration` by polling.
final class Recorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var converter: AVAudioConverter?
    private var writer: WAVFileWriter?
    private(set) var isRecording = false

    /// Called on the audio thread with each converted 16 kHz chunk
    /// (e.g. to feed live transcription). Set before `start`.
    var onSamples: (@Sendable ([Float]) -> Void)?

    static let sampleRate = MeetingPipeline.sampleRate

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(Recorder.sampleRate),
        channels: 1,
        interleaved: false
    )!

    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(buffer.count) / Double(Self.sampleRate)
    }

    /// RMS level of the most recent chunk, 0–1, for a meter.
    private(set) var level: Float = 0

    /// Start capturing. If `fileURL` is given, audio is continuously persisted
    /// there (crash-safe); the file is finalized on `stop()`.
    func start(writingTo fileURL: URL? = nil) throws {
        guard !isRecording else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        #endif

        lock.lock()
        buffer.removeAll()
        writer = try fileURL.map { try WAVFileWriter(url: $0, sampleRate: Self.sampleRate) }
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] pcmBuffer, _ in
            self?.consume(pcmBuffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stop, finalize the on-disk file (if any), and return everything captured.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        lock.lock(); defer { lock.unlock() }
        try? writer?.finalize()
        writer = nil
        return buffer
    }

    private func consume(_ pcmBuffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.targetFormat.sampleRate / pcmBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return pcmBuffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }

        let samples = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        level = min(1, sqrt(sumSquares / Float(samples.count)) * 6)

        let chunk = Array(samples)
        lock.lock()
        buffer.append(contentsOf: chunk)
        try? writer?.append(chunk)
        lock.unlock()

        onSamples?(chunk)
    }
}
