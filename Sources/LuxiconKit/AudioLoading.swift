import Foundation
import AudioCommon

extension MeetingPipeline {
    /// Load any audio file (wav/m4a/mp3/...) resampled to the pipeline's rate.
    public static func loadAudio(url: URL) throws -> [Float] {
        try AudioFileLoader.load(url: url, targetSampleRate: sampleRate)
    }
}
