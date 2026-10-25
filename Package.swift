// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LegatoKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "LegatoCore", targets: ["LegatoCore"]),
    ],
    targets: [
        .target(name: "LegatoCore"),
        .testTarget(name: "LegatoCoreTests", dependencies: ["LegatoCore"]),
    ],
    swiftLanguageModes: [.v6]
)
