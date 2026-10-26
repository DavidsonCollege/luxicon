import Foundation

/// Which diarization pipeline `MeetingPipeline` runs.
///
/// `.classic` is the vendored pipeline Luxicon has always shipped and is the
/// default everywhere. `.pyannoteV2` is speech-swift's newer pipeline, opt-in
/// for validation only (CLI `--diarizer v2`, or the hidden macOS key).
public enum DiarizationMethod: Codable, Sendable, Equatable {
    case classic
    case pyannoteV2(threshold: Float)

    public static let `default`: DiarizationMethod = .classic

    /// Validated on four meetings: 0.30-0.55 was safe, 0.6 collapsed one
    /// meeting to a single speaker.
    public static let v2DefaultThreshold: Float = 0.4

    /// Parses a CLI / defaults value: "classic" or "v2". `threshold` only
    /// applies to v2. Returns nil for anything else.
    public init?(cliValue: String, threshold: Float?) {
        switch cliValue.lowercased() {
        case "classic": self = .classic
        case "v2": self = .pyannoteV2(threshold: threshold ?? Self.v2DefaultThreshold)
        default: return nil
        }
    }
}
