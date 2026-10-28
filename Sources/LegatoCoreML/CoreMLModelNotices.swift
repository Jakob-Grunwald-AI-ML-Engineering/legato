import Foundation

/// Bundled, offline copies of the terms governing the downloadable model.
public enum CoreMLModelNotices {
    public static func gemmaDocuments() throws -> (notice: String, terms: String, restrictions: String) {
        func text(_ name: String) throws -> String {
            guard let url = Bundle.module.url(forResource: name, withExtension: "txt") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try String(contentsOf: url, encoding: .utf8)
        }
        return try (text("GemmaNotice"), text("GemmaTermsOfUse"), text("GemmaProhibitedUsePolicy"))
    }
}
