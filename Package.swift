// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sitdown",
    platforms: [
        .macOS("15.0"),
        .iOS("18.0"),
    ],
    products: [
        .library(name: "SitdownKit", targets: ["SitdownKit"]),
        .executable(name: "sitdown-cli", targets: ["SitdownCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/soniqo/speech-swift.git", from: "0.0.21"),
    ],
    targets: [
        .target(
            name: "SitdownKit",
            dependencies: [
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "ParakeetASR", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
            ]
        ),
        .executableTarget(
            name: "SitdownCLI",
            dependencies: ["SitdownKit"]
        ),
        .testTarget(
            name: "SitdownKitTests",
            dependencies: ["SitdownKit"]
        ),
    ]
)
