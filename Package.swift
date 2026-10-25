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
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
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
    ],
    swiftLanguageModes: [.v6]
)
