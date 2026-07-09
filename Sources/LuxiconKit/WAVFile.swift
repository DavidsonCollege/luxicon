import Foundation

/// Minimal 16-bit PCM mono WAV encode/decode for recording archival.
public enum WAVFile {
    public static let headerSize = 44

    /// RIFF/fmt/data header for `sampleCount` 16-bit mono samples.
    public static func header(sampleCount: Int, sampleRate: Int) -> Data {
        let dataSize = sampleCount * 2
        var data = Data(capacity: headerSize)

        func append(_ s: String) { data.append(contentsOf: s.utf8) }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF"); append32(UInt32(36 + dataSize)); append("WAVE")
        append("fmt "); append32(16)
        append16(1)                              // PCM
        append16(1)                              // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))         // byte rate
        append16(2)                              // block align
        append16(16)                             // bits per sample
        append("data"); append32(UInt32(dataSize))
        return data
    }

    /// Float32 (±1) → Int16 little-endian PCM bytes.
    public static func pcmData(samples: [Float]) -> Data {
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            pcm[i] = Int16(max(-1, min(1, s)) * 32767)
        }
        return pcm.withUnsafeBytes { Data($0) }
    }

    /// Encode mono Float32 samples as a complete 16-bit PCM WAV file.
    public static func encode(samples: [Float], sampleRate: Int) -> Data {
        header(sampleCount: samples.count, sampleRate: sampleRate) + pcmData(samples: samples)
    }

    public static func write(samples: [Float], sampleRate: Int, to url: URL) throws {
        try encode(samples: samples, sampleRate: sampleRate).write(to: url)
    }

    /// Rewrite the RIFF/data sizes from the actual file length. Recovers files
    /// whose writer died before `finalize()` (header still shows 0 samples).
    /// Returns the duration in seconds implied by the file length.
    @discardableResult
    public static func repairHeader(url: URL, sampleRate: Int) throws -> Double {
        let fileSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let sampleCount = max(0, (fileSize - headerSize) / 2)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(sampleCount: sampleCount, sampleRate: sampleRate))
        return Double(sampleCount) / Double(sampleRate)
    }
}

/// Incrementally writes a WAV file as audio arrives, so a crash mid-recording
/// loses at most the last unflushed chunk instead of the whole session.
/// Call `finalize()` on clean stop; an unfinalized file is recoverable with
/// `WAVFile.repairHeader`.
public final class WAVFileWriter {
    private let handle: FileHandle
    private let sampleRate: Int
    private(set) public var sampleCount = 0

    public var duration: Double { Double(sampleCount) / Double(sampleRate) }

    public init(url: URL, sampleRate: Int) throws {
        // Header is written with zero sizes and patched in finalize().
        try WAVFile.header(sampleCount: 0, sampleRate: sampleRate).write(to: url)
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.sampleRate = sampleRate
    }

    public func append(_ samples: [Float]) throws {
        try handle.write(contentsOf: WAVFile.pcmData(samples: samples))
        sampleCount += samples.count
    }

    public func finalize() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAVFile.header(sampleCount: sampleCount, sampleRate: sampleRate))
        try handle.close()
    }
}
