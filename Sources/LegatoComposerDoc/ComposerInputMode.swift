/// What new speech means, independent of the document's writing style.
public enum ComposerInputMode: String, Codable, CaseIterable, Sendable {
    case dictation, instructions
    public var toggled: Self { self == .dictation ? .instructions : .dictation }
}
