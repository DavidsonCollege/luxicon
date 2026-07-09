import Testing
import Foundation
@testable import LuxiconKit

@Suite struct WAVFileTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wavtest-\(UUID().uuidString).wav")
    }

    private func readDataChunkSize(_ url: URL) throws -> UInt32 {
        let data = try Data(contentsOf: url)
        return data[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    @Test func writerProducesSameBytesAsOneShotEncode() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let samples: [Float] = (0..<3200).map { sin(Float($0) * 0.05) }

        let writer = try WAVFileWriter(url: url, sampleRate: 16000)
        try writer.append(Array(samples[0..<1600]))
        try writer.append(Array(samples[1600...]))
        try writer.finalize()

        #expect(try Data(contentsOf: url) == WAVFile.encode(samples: samples, sampleRate: 16000))
    }

    @Test func repairRebuildsHeaderOfUnfinalizedFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Simulate a crash: append audio, never finalize — header still says 0 samples.
        let writer = try WAVFileWriter(url: url, sampleRate: 16000)
        try writer.append([Float](repeating: 0.25, count: 8000))  // 0.5 s
        #expect(try readDataChunkSize(url) == 0)

        let duration = try WAVFile.repairHeader(url: url, sampleRate: 16000)
        #expect(duration == 0.5)
        #expect(try readDataChunkSize(url) == 16000)

        // Repaired file must be loadable like any normal WAV.
        let loaded = try MeetingPipeline.loadAudio(url: url)
        #expect(abs(Double(loaded.count) - 8000) < 2)
    }
}
