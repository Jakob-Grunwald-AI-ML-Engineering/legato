// swift-tools-version: 6.2
import Foundation
import PackageDescription

// CI-ONLY SWITCH. With LEGATO_STUB_DEPS=1 the four heavy remote dependencies (FluidAudio, mlx-swift-lm,
// swift-huggingface, swift-transformers; MLX comes in through mlx-swift-lm) are dropped and replaced by local
// stub targets in Stubs/<Module> with the same module names. CI uses that to compile and test the package
// in seconds instead of minutes; the stubs have no behaviour (`fatalError`). Unset, the manifest is the real one.
// A dependency bump or a new call into one of these libraries needs the matching Stubs/<Module> file updated.
let stubDeps = ProcessInfo.processInfo.environment["LEGATO_STUB_DEPS"] == "1"

/// A product of a heavy remote package, or the same-named local stub target in stub mode.
func heavy(_ name: String, _ package: String) -> Target.Dependency {
    stubDeps ? .target(name: name) : .product(name: name, package: package)
}

/// Local stand-ins for the heavy modules (stub mode only). Version 5 mode: they are throwaway shims.
let stubTargets: [Target] = [
    .target(name: "LegatoANEMLL", path: "Stubs/LegatoANEMLL"),
    .target(name: "MLX", path: "Stubs/MLX", swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "MLXLMCommon", dependencies: ["MLX"], path: "Stubs/MLXLMCommon", swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "MLXLLM", dependencies: ["MLXLMCommon"], path: "Stubs/MLXLLM", swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "FluidAudio", path: "Stubs/FluidAudio", swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "HuggingFace", path: "Stubs/HuggingFace", swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "Tokenizers", path: "Stubs/Tokenizers", swiftSettings: [.swiftLanguageMode(.v5)]),
]

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
        .library(name: "LegatoCoreML", targets: ["LegatoCoreML"]),
        .library(name: "LegatoAppServices", targets: ["LegatoAppServices"]),
        .library(name: "LegatoMac", targets: ["LegatoMac"]),
        .library(name: "LegatoMeetings", targets: ["LegatoMeetings"]),
        .library(name: "LegatoClaude", targets: ["LegatoClaude"]),
        .library(name: "LegatoKeyboardCore", targets: ["LegatoKeyboardCore"]),
        .library(name: "LegatoVocabulary", targets: ["LegatoVocabulary"]),
    ],
    dependencies: stubDeps ? [] : [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "5.4.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3", traits: []),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "1.0.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.5"),
    ],
    targets: [
        .target(name: "LegatoCore"),
        .target(name: "LegatoCoreML", dependencies: ["LegatoCore", "LegatoModels", "LegatoANEMLL"], resources: [.process("Resources")]),
        .testTarget(name: "LegatoCoreMLTests", dependencies: ["LegatoCoreML", "LegatoCore", "LegatoModels"]),
        .testTarget(name: "LegatoCoreTests", dependencies: ["LegatoCore"]),
        // The keyboard extension links only this (Foundation only; it must not depend on LegatoCore).
        .target(name: "LegatoKeyboardCore"),
        .testTarget(name: "LegatoKeyboardCoreTests", dependencies: ["LegatoKeyboardCore"]),
        // The personal vocabulary (Foundation and NaturalLanguage only; like the keyboard core, it must not
        // depend on LegatoCore, so the keyboard extension can link it).
        .target(name: "LegatoVocabulary"),
        .testTarget(name: "LegatoVocabularyTests", dependencies: ["LegatoVocabulary"]),
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
                heavy("FluidAudio", "FluidAudio"),
            ]
        ),
        .testTarget(
            name: "LegatoFluidAudioTests",
            dependencies: [
                "LegatoFluidAudio", "LegatoCore", "LegatoModels",
                heavy("FluidAudio", "FluidAudio"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "LegatoEngines",
            dependencies: ["LegatoCore", "LegatoModels", "LegatoAppleSpeech", "LegatoFluidAudio"]
        ),
        .testTarget(
            name: "LegatoEnginesTests",
            dependencies: ["LegatoEngines", "LegatoCore", "LegatoModels", "LegatoAppleSpeech", "LegatoFluidAudio"]
        ),
        .testTarget(
            name: "LegatoPostProcessingTests",
            dependencies: ["LegatoPostProcessing", "LegatoCore", "LegatoModels", "LegatoMLX", "LegatoVocabulary"],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "LegatoMLX",
            dependencies: [
                "LegatoCore", "LegatoModels", "LegatoPostProcessing",
                heavy("MLXLLM", "mlx-swift-lm"),
                heavy("MLXLMCommon", "mlx-swift-lm"),
                heavy("HuggingFace", "swift-huggingface"),
                heavy("Tokenizers", "swift-transformers"),
            ]
        ),
        .target(
            name: "LegatoPostProcessing",
            dependencies: ["LegatoCore", "LegatoVocabulary", heavy("FluidAudio", "FluidAudio")]
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
                "LegatoCore", "LegatoModels", "LegatoEngines", "LegatoFluidAudio", "LegatoMLX", "LegatoCoreML", "LegatoPostProcessing",
                "LegatoAppleSpeech", "LegatoAudio", "LegatoMeetings", "LegatoClaude", "LegatoVocabulary",
            ]
        ),
        .testTarget(
            name: "LegatoAppServicesTests",
            dependencies: [
                "LegatoAppServices", "LegatoCore", "LegatoModels", "LegatoMLX", "LegatoPostProcessing", "LegatoVocabulary",
                "LegatoEngines", "LegatoMeetings", "LegatoClaude", "LegatoFluidAudio",
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
    ] + (stubDeps ? stubTargets : [
        .target(name: "LegatoANEMLL", dependencies: [
            .product(name: "Yams", package: "Yams"),
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "Hub", package: "swift-transformers"),
        ], path: "Vendor/ANEMLL/Sources/AnemllCore"),
    ]),
    swiftLanguageModes: [.v6]
)
