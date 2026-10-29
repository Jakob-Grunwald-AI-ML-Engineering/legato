// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "LegatoEvaluations", platforms: [.macOS(.v26)], products: [.executable(name: "PatchEvaluation", targets: ["PatchEvaluation"]), .executable(name: "AlternativeEvaluation", targets: ["AlternativeEvaluation"])], dependencies: [.package(name: "LegatoSnapshot", path: "source")], targets: [
.target(name: "EvaluationSupport"),
.executableTarget(name: "PatchEvaluation", dependencies: ["EvaluationSupport", .product(name: "LegatoCore", package: "LegatoSnapshot"), .product(name: "LegatoMac", package: "LegatoSnapshot"), .product(name: "LegatoKeyboardCore", package: "LegatoSnapshot")]),
.executableTarget(name: "AlternativeEvaluation", dependencies: ["EvaluationSupport", .product(name: "LegatoVocabulary", package: "LegatoSnapshot"), .product(name: "LegatoKeyboardCore", package: "LegatoSnapshot")]),
.testTarget(name: "EvaluationTests", dependencies: ["EvaluationSupport"])
])
