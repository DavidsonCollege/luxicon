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
        // Pinned past v0.0.21 for Gemma4Chat (on main, unreleased). Exact SHA —
        // move to a `from:` version once upstream tags a release containing it.
        .package(url: "https://github.com/soniqo/speech-swift.git",
                 revision: "e403d0bdd5e134ddbca076ca9e75fd28761e69b1"),
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
                .product(name: "Qwen3Chat", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "MLX", package: "mlx-swift"),
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
