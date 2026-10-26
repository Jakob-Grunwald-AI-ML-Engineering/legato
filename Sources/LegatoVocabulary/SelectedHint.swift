/// A term chosen for a hint list.
public struct SelectedHint: Sendable, Equatable {
    /// The correct surface form.
    public var text: String
    /// Alternative correct surfaces; never aliases (known mishearings).
    public var spellings: [String]

    public init(text: String, spellings: [String] = []) {
        self.text = text
        self.spellings = spellings
    }
}
