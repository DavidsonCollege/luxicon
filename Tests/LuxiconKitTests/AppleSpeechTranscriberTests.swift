import Testing
import AVFoundation
@testable import LuxiconKit

@Suite struct AppleSpeechTranscriberTests {

    @available(iOS 26.0, macOS 26.0, *)
    @Test func pcmBufferCarriesSamplesInNativeFormat() throws {
        let samples: [Float] = [0.0, 0.5, -0.5, 1.0]
        let buffer = try AppleSpeechTranscriber.pcmBuffer(
            from: samples, sampleRate: 16000, converting: nil)
        #expect(buffer.frameLength == 4)
        #expect(buffer.format.sampleRate == 16000)
        #expect(buffer.format.channelCount == 1)
        let out = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 4)
        #expect(Array(out) == samples)
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Test func pcmBufferHandlesEmptyInput() throws {
        let buffer = try AppleSpeechTranscriber.pcmBuffer(
            from: [], sampleRate: 16000, converting: nil)
        #expect(buffer.frameLength == 0)
        #expect(buffer.format.sampleRate == 16000)
        #expect(buffer.format.channelCount == 1)
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Test func pcmBufferConvertsSampleRate() throws {
        // 1 s of signal at 16 kHz converts to ~32000 frames at 32 kHz —
        // same duration, double the frame count.
        let samples = [Float](repeating: 0.25, count: 16000)
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 32000, channels: 1, interleaved: false)!
        let buffer = try AppleSpeechTranscriber.pcmBuffer(
            from: samples, sampleRate: 16000, converting: target)
        #expect(buffer.format.sampleRate == 32000)
        // Allow converter edge effects: within 1% of expected 32000 frames.
        #expect(abs(Int(buffer.frameLength) - 32000) < 320)
    }
}
