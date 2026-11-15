// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PocketKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "UnalomeDesign", targets: ["UnalomeDesign"]),
        .library(name: "ChatCore", targets: ["ChatCore"]),
        .library(name: "ModelCatalog", targets: ["ModelCatalog"]),
        .library(name: "MLXEngine", targets: ["MLXEngine"]),
        .library(name: "AppleEngine", targets: ["AppleEngine"]),
        .library(name: "Features", targets: ["Features"]),
    ],
    dependencies: [
        // The default "FoundationModelsIntegration" trait bridges MLX into FoundationModels;
        // this app talks to FoundationModels directly, so the trait is turned off.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3"), traits: []),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMinor(from: "1.4.0")),
        // Markdown parsing (CommonMark + GitHub tables) for replies; rendered by Features/Markdown.
        .package(url: "https://github.com/swiftlang/swift-markdown", .upToNextMinor(from: "0.9.0")),
    ],
    targets: [
        .target(
            name: "UnalomeDesign",
            resources: [.process("Resources")]
        ),
        .target(name: "ChatCore"),
        .target(
            name: "ModelCatalog",
            resources: [.process("Resources")]
        ),
        .target(
            name: "MLXEngine",
            dependencies: [
                "ChatCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .target(
            name: "AppleEngine",
            dependencies: ["ChatCore", "ModelCatalog"]
        ),
        .target(
            name: "Features",
            dependencies: [
                "UnalomeDesign", "ChatCore", "ModelCatalog",
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .testTarget(name: "ChatCoreTests", dependencies: ["ChatCore"]),
        .testTarget(name: "ModelCatalogTests", dependencies: ["ModelCatalog"]),
        .testTarget(
            name: "MLXEngineTests",
            dependencies: ["MLXEngine", "ChatCore", "ModelCatalog", .product(name: "MLX", package: "mlx-swift")]
        ),
        .testTarget(name: "FeaturesTests", dependencies: ["Features", "ChatCore", "ModelCatalog"]),
    ],
    swiftLanguageModes: [.v6]
)
