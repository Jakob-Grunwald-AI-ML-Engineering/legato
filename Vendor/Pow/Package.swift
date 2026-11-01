// swift-tools-version: 5.7
import PackageDescription
let package = Package(name: "Pow", platforms: [.iOS(.v15), .macOS(.v12)], products: [.library(name: "Pow", targets: ["Pow"])], targets: [.target(name: "Pow", resources: [.process("Assets.xcassets")])])
