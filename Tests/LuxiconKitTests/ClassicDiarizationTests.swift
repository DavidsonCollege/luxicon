import Foundation
import Testing
import SpeechVAD
@testable import LuxiconKit

@Suite struct ClassicDiarizationTests {

    /// Deterministic generator so the synthetic embeddings are identical every run.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Unit vector `centroid` plus noise scaled so the expected cosine
    /// distance from the centroid is `cosineNoise`.
    static func noisy(_ centroid: [Float], cosineNoise: Float, rng: inout SplitMix64) -> [Float] {
        // cos = 1 / sqrt(1 + r²)  →  r = sqrt(1/cos² − 1)
        let cos = 1 - cosineNoise
        let r = (1 / (cos * cos) - 1).squareRoot()
        var noise = (0..<centroid.count).map { _ in Float.random(in: -1...1, using: &rng) }
        let norm = noise.reduce(0) { $0 + $1 * $1 }.squareRoot()
        noise = noise.map { $0 / norm * r }
        return zip(centroid, noise).map { $0 + $1 }
    }

    @Test func classicClusteringSeparatesTwoSyntheticSpeakers() {
        let dim = 256
        var a = [Float](repeating: 0, count: dim); a[0] = 1
        var b = [Float](repeating: 0, count: dim); b[1] = 1
        var rng = SplitMix64(state: 42)

        // 20 per speaker, interleaved, each from its own window so the
        // same-window constraint never blocks a merge.
        var items: [ClassicDiarizationHelpers.ClusterItem] = []
        var truth: [Int] = []
        for i in 0..<40 {
            let speaker = i % 2
            items.append(ClassicDiarizationHelpers.ClusterItem(
                windowIndex: i, localSpeakerId: 0,
                embedding: Self.noisy(speaker == 0 ? a : b, cosineNoise: 0.05, rng: &rng)))
            truth.append(speaker)
        }

        let (assignment, centroids) = ClassicDiarizationHelpers.constrainedAgglomerativeClustering(
            items: items, threshold: DiarizationConfig.default.clusteringThreshold)

        #expect(centroids.count == 2)
        #expect(Set(assignment).count == 2)
        let clusterOfA = Set(zip(assignment, truth).filter { $0.1 == 0 }.map(\.0))
        let clusterOfB = Set(zip(assignment, truth).filter { $0.1 == 1 }.map(\.0))
        #expect(clusterOfA.count == 1)
        #expect(clusterOfB.count == 1)
        #expect(clusterOfA != clusterOfB)
    }

    @Test func classicClusteringNeverMergesSameWindowItems() {
        // Two near-identical embeddings from the same window must stay apart.
        let e: [Float] = [1, 0, 0, 0]
        let items = [
            ClassicDiarizationHelpers.ClusterItem(windowIndex: 0, localSpeakerId: 0, embedding: e),
            ClassicDiarizationHelpers.ClusterItem(windowIndex: 0, localSpeakerId: 1, embedding: e),
        ]
        let (assignment, _) = ClassicDiarizationHelpers.constrainedAgglomerativeClustering(
            items: items, threshold: DiarizationConfig.default.clusteringThreshold)
        #expect(assignment[0] != assignment[1])
    }
}
