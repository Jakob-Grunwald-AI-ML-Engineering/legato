import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}
@main struct ArtifactProvenanceTests {
    static func main() throws {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixtures = base.appending(path: "conversion/results")
        let output = base.appending(path: ".cache/artifact-provenance-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let empty = ArtifactProvenance.read(folder: output)
        require(empty.modelValidation == nil && empty.manifestSHA256 == nil, "missing manifest cannot invent validation or artifact identity")
        let file = output.appending(path: "artifact-manifest.json")
        try Data(contentsOf: fixtures.appending(path: "qwen3-06b-lut6-artifact-manifest.json")).write(to: file)
        let lut6 = ArtifactProvenance.read(folder: output)
        require(lut6.modelValidation == "failedStrictNumericGate;prefixTop1Mismatch", "LUT6 rows must retain the actual failed strict gate and prefix mismatch")
        require(lut6.manifestSHA256 == CommandLine.arguments[1], "artifact identity hashes the exact on-disk manifest bytes")
        try Data(contentsOf: fixtures.appending(path: "qwen3-06b-fp16-artifact-manifest.json")).write(to: file)
        let fp16 = ArtifactProvenance.read(folder: output)
        require(fp16.modelValidation == "failedNumericGate;prefixTop1Matched", "FP16 artifact cannot inherit LUT6 validation label")
        require(fp16.manifestSHA256 == CommandLine.arguments[2], "switching actual artifact changes its manifest identity")
        try Data().write(to: file)
        let malformed = ArtifactProvenance.read(folder: output)
        require(malformed.modelValidation == nil, "malformed manifest cannot claim validation")
        require(malformed.manifestSHA256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "readable malformed manifest still retains exact byte identity")
        print("PASS: actual LUT6/FP16 manifest labels, exact file hashes, missing and malformed metadata")
    }
}
