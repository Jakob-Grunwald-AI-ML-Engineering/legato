// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LegatoKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "LegatoCore", targets: ["LegatoCore"]),
        .library(name: "LegatoAudio", targets: ["LegatoAudio"]),
        .library(name: "LegatoAppleSpeech", targets: ["LegatoAppleSpeech"]),
        .library(name: "LegatoModels", targets: ["LegatoModels"]),
        .library(name: "LegatoFluidAudio", targets: ["LegatoFluidAudio"]),
        .library(name: "LegatoEngines", targets: ["LegatoEngines"]),
        .library(name: "LegatoPostProcessing", targets: ["LegatoPostProcessing"]),
        .library(name: "LegatoMLX", targets: ["LegatoMLX"]),
        .library(name: "LegatoAppServices", targets: ["LegatoAppServices"]),
        .library(name: "LegatoMac", targets: ["LegatoMac"]),
        .library(name: "LegatoMeetings", targets: ["LegatoMeetings"]),
        .library(name: "LegatoClaude", targets: ["LegatoClaude"]),
        .library(name: "LegatoKeyboardCore", targets: ["LegatoKeyboardCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3", traits: []),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "1.0.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.5"),
    ],
    targets: [
        .target(name: "LegatoCore"),
        .testTarget(name: "LegatoCoreTests", dependencies: ["LegatoCore"]),
        // The keyboard extension links only this (Foundation only; it must not depend on LegatoCore).
        .target(name: "LegatoKeyboardCore"),
        .testTarget(name: "LegatoKeyboardCoreTests", dependencies: ["LegatoKeyboardCore"]),
        .target(name: "LegatoAudio", dependencies: ["LegatoCore"]),
        .testTarget(name: "LegatoAudioTests", dependencies: ["LegatoAudio", "LegatoCore"]),
        .target(name: "LegatoAppleSpeech", dependencies: ["LegatoCore"]),
        .testTarget(
            name: "LegatoAppleSpeechTests",
            dependencies: ["LegatoAppleSpeech", "LegatoCore"],
            resources: [.copy("Fixtures")]
        ),
        .target(name: "LegatoModels", dependencies: ["LegatoCore"]),
        .testTarget(name: "LegatoModelsTests", dependencies: ["LegatoModels", "LegatoCore"]),
        .target(
            name: "LegatoFluidAudio",
            dependencies: [
                "LegatoCore",
                "LegatoModels",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(
            name: "LegatoFluidAudioTests",
            dependencies: [
                "LegatoFluidAudio", "LegatoCore", "LegatoModels",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "LegatoEngines",
            dependencies: ["LegatoCore", "LegatoModels", "LegatoAppleSpeech", "LegatoFluidAudio"]
        ),
        .testTarget(
            name: "LegatoEnginesTests",
            dependencies: ["LegatoEngines", "LegatoCore", "LegatoModels"]
        ),
        .testTarget(
            name: "LegatoPostProcessingTests",
            dependencies: ["LegatoPostProcessing", "LegatoCore", "LegatoModels", "LegatoMLX"],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "LegatoMLX",
            dependencies: [
                "LegatoCore", "LegatoModels", "LegatoPostProcessing",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .target(
            name: "LegatoPostProcessing",
            dependencies: ["LegatoCore", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .testTarget(
            name: "LegatoMLXTests",
            dependencies: ["LegatoMLX", "LegatoCore", "LegatoModels", "LegatoPostProcessing"]
        ),
        .executableTarget(
            name: "legato-bench",
            dependencies: [
                "LegatoEngines", "LegatoCore", "LegatoModels", "LegatoAppleSpeech", "LegatoFluidAudio",
            ],
            resources: [.copy("Clips")]
        ),
        .testTarget(name: "legato-benchTests", dependencies: ["legato-bench"]),
        // What both apps share above the engines: the model catalog and picks, cleanup settings and runs.
        .target(
            name: "LegatoAppServices",
            dependencies: [
                "LegatoCore", "LegatoModels", "LegatoEngines", "LegatoFluidAudio", "LegatoMLX", "LegatoPostProcessing",
                "LegatoAppleSpeech", "LegatoAudio", "LegatoMeetings", "LegatoClaude",
            ]
        ),
        .testTarget(
            name: "LegatoAppServicesTests",
            dependencies: [
                "LegatoAppServices", "LegatoCore", "LegatoModels", "LegatoMLX", "LegatoPostProcessing",
                "LegatoMeetings", "LegatoClaude", "LegatoFluidAudio",
            ]
        ),
        .target(name: "LegatoMac", dependencies: ["LegatoCore"]),
        .testTarget(name: "LegatoMacTests", dependencies: ["LegatoMac", "LegatoCore"]),
        // Meeting notes: a multi-stream session, its store, recovery, echo de-duplication and export. Core only.
        .target(name: "LegatoMeetings", dependencies: ["LegatoCore"]),
        .testTarget(
            name: "LegatoMeetingsTests",
            dependencies: ["LegatoMeetings", "LegatoCore"],
            resources: [.copy("Fixtures")]
        ),
        // The Claude API as an opt-in summary backend, and where its key lives. Core only.
        .target(name: "LegatoClaude", dependencies: ["LegatoCore"]),
        .testTarget(name: "LegatoClaudeTests", dependencies: ["LegatoClaude", "LegatoCore"]),
    ],
    swiftLanguageModes: [.v6]
)
