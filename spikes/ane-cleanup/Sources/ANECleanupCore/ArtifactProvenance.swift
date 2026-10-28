import Foundation
import CryptoKit

/// Optional artifact evidence, distinct from a model source revision or device clearance.
public struct ArtifactProvenance: Sendable {
    public var modelValidation: String?
    public var manifestSHA256: String?
    private struct Manifest: Decodable { let modelValidation: String? }
    public static func read(folder: URL) -> Self {
        guard let bytes = try? Data(contentsOf: folder.appending(path: "artifact-manifest.json")) else { return Self() }
        return Self(modelValidation: (try? JSONDecoder().decode(Manifest.self, from: bytes))?.modelValidation,
                    manifestSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}
