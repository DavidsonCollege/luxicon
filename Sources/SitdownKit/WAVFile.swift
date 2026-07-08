import Foundation

/// Minimal 16-bit PCM mono WAV encode/decode for recording archival.
public enum WAVFile {
    /// Encode mono Float32 samples (clamped to ±1) as a 16-bit PCM WAV file.
    public static func encode(samples: [Float], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)

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

        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            pcm[i] = Int16(max(-1, min(1, s)) * 32767)
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    public static func write(samples: [Float], sampleRate: Int, to url: URL) throws {
        try encode(samples: samples, sampleRate: sampleRate).write(to: url)
    }
}
