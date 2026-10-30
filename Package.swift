// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LegatoKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "LegatoSoniox", targets: ["LegatoSoniox"]),
        .library(name: "LegatoRoom", targets: ["LegatoRoom"]),
        .library(name: "LegatoComposerDoc", targets: ["LegatoComposerDoc"]),
        .library(name: "LegatoDevHarness", targets: ["LegatoDevHarness"]),
        .library(name: "LegatoCore", targets: ["LegatoCore"]),
        .library(name: "LegatoKeyboardCore", targets: ["LegatoKeyboardCore"]),
        .library(name: "LegatoVocabulary", targets: ["LegatoVocabulary"]),
        .library(name: "LegatoAudio", targets: ["LegatoAudio"]),
        .library(name: "LegatoAppServices", targets: ["LegatoAppServices"]),
        .library(name: "LegatoMac", targets: ["LegatoMac"]),
        .library(name: "LegatoClaude", targets: ["LegatoClaude"]),
    ],
    dependencies: [
        .package(url: "https://github.com/EmergeTools/Pow.git", exact: "1.0.5"),
    ],
    targets: [
        .testTarget(name: "LegatoRoomTests", dependencies: ["LegatoRoom", "LegatoComposerDoc"]),
        .target(name: "LegatoSoniox", dependencies: ["LegatoRoom", "LegatoComposerDoc"]),
        .testTarget(name: "LegatoSonioxTests", dependencies: ["LegatoSoniox", "LegatoRoom", "LegatoComposerDoc"]),
        .target(name: "LegatoComposerDoc"),
        .target(name: "LegatoRoom", dependencies: ["LegatoComposerDoc", "LegatoVocabulary"]),
        .testTarget(name: "LegatoComposerDocTests", dependencies: ["LegatoComposerDoc"]),
        .target(name: "LegatoDevHarness"),
        .testTarget(name: "LegatoDevHarnessTests", dependencies: ["LegatoDevHarness"]),
        .target(name: "LegatoCore"),
        .testTarget(name: "LegatoCoreTests", dependencies: ["LegatoCore"]),
        .target(name: "LegatoKeyboardCore"),
        .testTarget(name: "LegatoKeyboardCoreTests", dependencies: ["LegatoKeyboardCore"]),
        .target(name: "LegatoVocabulary"),
        .testTarget(name: "LegatoVocabularyTests", dependencies: ["LegatoVocabulary"]),
        .target(name: "LegatoAudio", dependencies: ["LegatoCore", "LegatoAudioBridge"]),
        .testTarget(name: "LegatoAudioTests", dependencies: ["LegatoAudio", "LegatoCore", "LegatoAudioBridge"]),
        .target(name: "LegatoAppServices", dependencies: ["LegatoCore", "LegatoVocabulary"]),
        .testTarget(name: "LegatoAppServicesTests", dependencies: ["LegatoAppServices", "LegatoCore", "LegatoVocabulary"]),
        .target(name: "LegatoMac", dependencies: ["LegatoCore"]),
        .testTarget(name: "LegatoMacTests", dependencies: ["LegatoMac", "LegatoCore"]),
        .target(name: "LegatoClaude", dependencies: ["LegatoCore"]),
        .testTarget(name: "LegatoClaudeTests", dependencies: ["LegatoClaude", "LegatoCore"]),
        .target(name: "LegatoAudioBridge", publicHeadersPath: "include"),
    ],
    swiftLanguageModes: [.v6]
)
