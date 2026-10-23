import Foundation

/// A single enrolled voice, exported as a small JSON file so it can move
/// between devices (AirDrop, Files). Deliberately not a transcript envelope:
/// `TranscriptLibrary.parse` ignores it.
public struct VoicePrintFile: Codable, Sendable, Equatable {
    public var kind: String = "voiceprint"
    public var schemaVersion: Int = 1
    public var name: String
    public var createdAt: Date
    public var embedding: [Float]

    public static let filename = "luxicon-voiceprint.json"

    public init(name: String, createdAt: Date = .now, embedding: [Float]) {
        self.name = name
        self.createdAt = createdAt
        self.embedding = embedding
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// nil unless this is a version-1 voiceprint with a usable embedding.
    public static func decode(_ data: Data) -> VoicePrintFile? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(VoicePrintFile.self, from: data),
              file.kind == "voiceprint", file.schemaVersion == 1,
              !file.embedding.isEmpty else { return nil }
        return file
    }
}
