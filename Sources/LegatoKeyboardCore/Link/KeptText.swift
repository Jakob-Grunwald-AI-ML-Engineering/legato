import Foundation

/// Dictated text the keyboard could not place in a field, held for the user to insert or copy. One item: a new one
/// replaces the old. Lives in the App Group (`LinkStore`) so it survives field switches and the keyboard closing.
public struct KeptText: Codable, Sendable, Equatable {
    public var text: String
    public var at: Date

    public init(text: String, at: Date = Date()) {
        self.text = text
        self.at = at
    }

    /// The word row's view of it: the end of the text (what was said last), cut from the head.
    public func preview(maxCharacters: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flat.count > maxCharacters else { return flat }
        return "…" + flat.suffix(max(1, maxCharacters - 1))
    }
}

public struct KeptTextStore: Sendable {
    public static let key = "keyboard.keptText"
    private let store: LinkStore

    public init(_ store: LinkStore) { self.store = store }

    public func read() -> KeptText? { store.read(KeptText.self, forKey: Self.key) }

    /// Keeps `text` (trimmed) in place of any earlier item; nothing happens for blank text. Returns what was stored.
    @discardableResult
    public func keep(_ text: String, at now: Date = Date()) -> KeptText? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = KeptText(text: trimmed, at: now)
        store.write(item, forKey: Self.key)
        return item
    }

    public func clear() { store.remove(forKey: Self.key) }
}
