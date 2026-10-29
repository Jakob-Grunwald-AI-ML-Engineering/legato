// swift-tools-version: 6.2
// Spike #95 on the Mac: the continuous cleanup-agent workload (LegatoMLX's ContinuousAgentProbe) on Core ML
// (ANEMLL, Neural Engine), MLX GPU and MLX CPU, Qwen3 1.7B and 0.6B. Real dependencies (no stubs).
//
// MLX needs the Metal shaders that only an Xcode build compiles (plain `swift run` fails at the first MLX
// array), and Release keeps MLX's C++ CPU kernels optimized. From this directory:
//
//   xcodebuild build -quiet -scheme ContinuousAgent -destination 'platform=macOS' -configuration Release \
//     -derivedDataPath .build/xcode
//   .build/xcode/Build/Products/Release/continuous-agent                      # the whole matrix (6 runs)
//   .build/xcode/Build/Products/Release/continuous-agent --backend mlx-cpu --model qwen3-0.6b --out mlx-cpu-0.6b.jsonl
//
// Flags: --backend coreml|mlx-gpu|mlx-cpu|all (comma lists too), --model qwen3-1.7b|qwen3-0.6b|all, --wps 2.5,
// --repeats 3 (fresh-session passes, seed + rep - 1), --warm 1|0 (one more pass on the last session), --seed 95,
// --window 1000, --root (default ~/Library/Application Support/Legato/Models, the Mac app's own store; a model
// missing there downloads once, at its pinned revision, and is reused by every later run and by the app),
// --out (JSON lines; both tables go to the same name .txt). One pass is 562 words, about 225 s at 2.5 words/s, so
// one combination takes about 4 × 3.75 min plus load; the whole matrix about 90 min.
import PackageDescription

let package = Package(
    name: "ContinuousAgent",
    platforms: [.macOS(.v26)],
    dependencies: [.package(name: "LegatoKit", path: "../..")],
    targets: [
        .executableTarget(name: "continuous-agent", dependencies: [
            .product(name: "LegatoCore", package: "LegatoKit"),
            .product(name: "LegatoCoreML", package: "LegatoKit"),
            .product(name: "LegatoMLX", package: "LegatoKit"),
            .product(name: "LegatoModels", package: "LegatoKit"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
