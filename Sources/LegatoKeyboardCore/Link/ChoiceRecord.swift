import Foundation

/// keyboard -> app (`link.choice.<uuid>`): the user replaced `original` with `chosen` from the word row,
/// so the app can learn from it. One key per choice, so concurrent writes can't collide; the app lists
/// and deletes them on `LinkChannel.Note.choice` and when it starts listening.
public struct ChoiceRecord: Codable, Sendable, Equatable {
    public var original: String
    public var chosen: String
    /// Whether the chosen word came from the personal vocabulary (rather than the spell checker).
    public var fromVocabulary: Bool
    public var at: Date

    public init(original: String, chosen: String, fromVocabulary: Bool, at: Date) {
        self.original = original
        self.chosen = chosen
        self.fromVocabulary = fromVocabulary
        self.at = at
    }
}

/// The keyboard's side of the choice channel.
public enum ChoiceWriter {
    /// Writes `record` under its own key and posts the note.
    public static func write(
        _ record: ChoiceRecord, to store: LinkStore, id: String = UUID().uuidString,
        post: (String) -> Void = { DarwinObserver.post($0) }
    ) {
        store.write(record, forKey: LinkChannel.Key.choicePrefix + id)
        post(LinkChannel.Note.choice)
    }
}
