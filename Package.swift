// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Luxicon",
    platforms: [
        .macOS("15.0"),
        .iOS("18.0"),
    ],
    products: [
        .library(name: "LuxiconKit", targets: ["LuxiconKit"]),
        .executable(name: "luxicon-cli", targets: ["LuxiconCLI"]),
        .executable(name: "luxicon-mcp", targets: ["LuxiconMCP"]),
    ],
    dependencies: [
        // Tag v0.0.28, pinned by exact SHA: classic diarization is vendored
        // (ClassicDiarization/) and Parakeet output was checked against the
        // previous pin, so a bump must be a deliberate, re-verified change.
        .package(url: "https://github.com/soniqo/speech-swift.git",
                 revision: "231f8eb9f0971fee335fef49f42d2975e4fbf8bc"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        // Direct dependency (already transitive via speech-swift) so LuxiconKit
        // can bound the MLX buffer cache during long pipeline runs.
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.30.0"),
    ],
    targets: [
        .target(
            name: "LuxiconKit",
            dependencies: [
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "ParakeetASR", package: "speech-swift"),
                .product(name: "ParakeetStreamingASR", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                // The vendored classic diarizer (ClassicDiarization/) defines MLXNN modules.
                .product(name: "MLXNN", package: "mlx-swift"),
            ]
        ),
        .executableTarget(
            name: "LuxiconCLI",
            dependencies: ["LuxiconKit"]
        ),
        .executableTarget(
            name: "LuxiconMCP",
            dependencies: [
                "LuxiconKit",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "LuxiconKitTests",
            dependencies: ["LuxiconKit"]
        ),
    ]
)
