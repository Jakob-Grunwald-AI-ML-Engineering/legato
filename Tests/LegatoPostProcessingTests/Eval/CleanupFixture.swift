import Foundation

/// One messy dictation transcript with what a good cleanup of it must and must not contain.
struct CleanupFixture: Codable, Sendable, Equatable {
    var name: String
    /// `de`, `en` or `mixed` (a transcript with words of the other language in it).
    var language: String
    /// `short` (one sentence) or `long` (five or more).
    var length: String
    var locale: String
    var input: String
    /// The user's names and terms; may be empty.
    var vocabulary: [String]
    /// Terms the cleaned text must hold, matched case-sensitively.
    var mustContain: [String]
    /// Terms the cleaned text must not hold (left-over spoken forms, misrecognitions, hallucinations),
    /// matched case-sensitively.
    var mustNotContain: [String]
    /// A hand-written good cleanup of `input`.
    var reference: String
}

/// The two halves of the fixture set. Prompts are tuned on `dev`; `heldout` is read once, at the end.
enum CleanupSplit: String, CaseIterable, Sendable {
    case dev
    case heldout
}

enum CleanupFixtures {
    /// The fixtures of `split`, sorted by file name.
    static func load(_ split: CleanupSplit) throws -> [CleanupFixture] {
        guard let dir = Bundle.module.url(
            forResource: split.rawValue, withExtension: nil, subdirectory: "Fixtures/cleanup")
        else { throw FixtureError.missingFolder(split.rawValue) }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { try JSONDecoder().decode(CleanupFixture.self, from: Data(contentsOf: $0)) }
    }

    enum FixtureError: Error { case missingFolder(String) }
}
