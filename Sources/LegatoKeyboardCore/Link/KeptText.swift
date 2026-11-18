import Foundation

/// Text the keyboard could not verify in the field. Only undelivered speech is safe to insert at a new cursor.
/// The App Group keeps one recovery item across field switches and keyboard reopen.
public struct KeptText: Codable, Sendable, Equatable {
    public var text: String
    public var at: Date
    public private(set) var id: UUID?
    /// Identifies where recovery was created. The item can be used explicitly in a later draft.
    public var draftID: String?
    /// Persist before dispatch. On reopen, the keyboard cannot infer whether an interrupted insertion landed.
    public var insertion: UUID?

    public enum InsertionResult: Sendable { case confirmed, refusedBeforeWrite, uncertain }
    public enum Kind: String, Codable, Sendable { case speech, cleanupRewrite }
    /// Items stored before this distinction only contained undelivered speech.
    public private(set) var kind: Kind?
    public var offersInsertion: Bool { kind != .cleanupRewrite }

    public mutating func beginInsertion() -> Bool {
        guard offersInsertion, insertion == nil else { return false }
        insertion = UUID()
        return true
    }

    public func resolvingInsertion(_ result: InsertionResult) -> Self? {
        switch result {
        case .confirmed: return nil
        case .refusedBeforeWrite:
            var editable = self
            editable.insertion = nil
            return editable
        case .uncertain: return self
        }
    }

    public init(text: String, at: Date = Date(), draftID: String? = nil, kind: Kind = .speech) {
        self.text = text
        self.at = at
        self.draftID = draftID
        self.id = UUID()
        self.kind = kind
    }

    /// Keep undelivered speech ahead of an unconfirmed rewrite. The latter is also retained in History.
    public static func preferred(_ candidate: Self, over existing: Self?) -> Self {
        if !candidate.isShowable { return existing ?? candidate }
        if !candidate.offersInsertion, let existing, existing.offersInsertion { return existing }
        return candidate
    }

    mutating func ensureIdentity() {
        if id == nil { id = UUID() }
    }

    /// Recovery written before draft identity was available has no valid source.
    public var isShowable: Bool { draftID != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The word row's view of it: the start of the text, which is what makes it recognisable, cut from the tail.
    public func preview(maxCharacters: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flat.count > maxCharacters else { return flat }
        return flat.prefix(max(1, maxCharacters - 1)) + "…"
    }
}

public struct KeptTextStore: Sendable {
    public static let key = "keyboard.keptText"
    private let store: LinkStore

    public init(_ store: LinkStore) { self.store = store }

    /// The item when it can be shown (`KeptText.isShowable`). Anything else stored under the key (an older format, an
    /// item without its draft, blank text) is removed: the row never shows an empty or stale item.
    public func read() -> KeptText? {
        guard var item = store.read(KeptText.self, forKey: Self.key), item.isShowable else {
            if store.hasValue(forKey: Self.key) { clear() }
            return nil
        }
        if item.id == nil {
            item.ensureIdentity()
            store.write(item, forKey: Self.key)
        }
        return item
    }

    /// Keeps the preferred usable recovery item and returns what the row should show.
    @discardableResult
    public func keep(_ text: String, draftID: String, kind: KeptText.Kind = .speech, at now: Date = Date()) -> KeptText? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let current = read()
        let item = KeptText.preferred(.init(text: trimmed, at: now, draftID: draftID, kind: kind), over: current)
        if item.id != current?.id { store.write(item, forKey: Self.key) }
        return item
    }

    public func clear() { store.remove(forKey: Self.key) }

    /// Replace only this item. A late receipt for an earlier insertion cannot remove newer recovery.
    @discardableResult
    public func replace(_ expected: KeptText, with item: KeptText?) -> Bool {
        guard let current = read(), current.id == expected.id, current.insertion == expected.insertion else { return false }
        if let item { store.write(item, forKey: Self.key) } else { clear() }
        return true
    }
}
