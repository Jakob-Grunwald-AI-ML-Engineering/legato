// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LegatoKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "LegatoCore", targets: ["LegatoCore"]),
        .library(name: "LegatoAudio", targets: ["LegatoAudio"]),
        .library(name: "LegatoAppleSpeech", targets: ["LegatoAppleSpeech"]),
        .library(name: "LegatoKeyboardCore", targets: ["LegatoKeyboardCore"]),
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
    ],
    swiftLanguageModes: [.v6]
)
