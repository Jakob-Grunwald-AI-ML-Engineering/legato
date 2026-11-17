import Foundation

/// Dictated text the keyboard could not place in a field, held for the user to insert or copy. One item: a new one
/// replaces the old. Lives in the App Group (`LinkStore`) so it survives field switches and the keyboard closing.
public struct KeptText: Codable, Sendable, Equatable {
    public var text: String
    public var at: Date
    /// The draft it was kept from (the keyboard's draft identity): sending or clearing that draft ends it.
    public var draftID: String?

    public init(text: String, at: Date = Date(), draftID: String? = nil) {
        self.text = text
        self.at = at
        self.draftID = draftID
    }

    /// Something to show: text that is not blank, from a draft (`draftID`). An item from an older format or without its
    /// draft is stale: nothing would ever end it.
    public var isShowable: Bool { draftID != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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

    /// The item when it can be shown (`KeptText.isShowable`). Anything else stored under the key (an older format, an
    /// item without its draft, blank text) is removed: the row never shows an empty or stale item.
    public func read() -> KeptText? {
        guard let item = store.read(KeptText.self, forKey: Self.key), item.isShowable else {
            if store.hasValue(forKey: Self.key) { clear() }
            return nil
        }
        return item
    }

    /// Keeps `text` (trimmed) for draft `draftID` in place of any earlier item; nothing happens for blank text. Returns
    /// what was stored.
    @discardableResult
    public func keep(_ text: String, draftID: String, at now: Date = Date()) -> KeptText? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = KeptText(text: trimmed, at: now, draftID: draftID)
        store.write(item, forKey: Self.key)
        return item
    }

    public func clear() { store.remove(forKey: Self.key) }

    /// Draft `draftID` was sent or cleared: an item kept from it goes too (it belonged to that message). Returns whether
    /// one went.
    @discardableResult
    public func draftEnded(_ draftID: String) -> Bool {
        guard let item = read(), item.draftID == draftID else { return false }
        clear()
        return true
    }
}
