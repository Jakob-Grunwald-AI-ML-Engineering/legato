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
    ],
    targets: [
        .target(name: "LegatoCore"),
        .testTarget(name: "LegatoCoreTests", dependencies: ["LegatoCore"]),
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
    ],
    swiftLanguageModes: [.v6]
)
