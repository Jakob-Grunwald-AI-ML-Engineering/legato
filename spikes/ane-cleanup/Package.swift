// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ANECleanupSpike",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "ANECleanupCore", targets: ["ANECleanupCore"])],
    dependencies: [
        .package(name: "LegatoKit", path: "../.."),
        .package(path: ".cache/Anemll-Anemll-f4ad26d/anemll-swift-cli"),
    ],
    targets: [
        .target(name: "ANECleanupCore", dependencies: [
            .product(name: "AnemllCore", package: "anemll-swift-cli"),
            .product(name: "LegatoAudio", package: "LegatoKit"),
            .product(name: "LegatoAppleSpeech", package: "LegatoKit"),
            .product(name: "LegatoCore", package: "LegatoKit"),
            .product(name: "LegatoMLX", package: "LegatoKit"),
            .product(name: "LegatoPostProcessing", package: "LegatoKit"),
        ]),
    ]
)
