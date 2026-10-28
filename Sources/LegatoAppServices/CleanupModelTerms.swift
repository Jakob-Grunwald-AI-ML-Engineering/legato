import LegatoCoreML

/// Presented before the model's download. Acceptance covers its governing terms and use restrictions.
public struct CleanupModelTerms: Identifiable, Sendable {
    public let id: String
    public let notice: String
    public let terms: String
    public let restrictions: String
    public static func forModel(_ id: String) throws -> Self? {
        guard id == CoreMLModels.gemma3_1bID else { return nil }
        let documents = try CoreMLModelNotices.gemmaDocuments()
        return .init(id: id, notice: documents.notice, terms: documents.terms, restrictions: documents.restrictions)
    }
}
