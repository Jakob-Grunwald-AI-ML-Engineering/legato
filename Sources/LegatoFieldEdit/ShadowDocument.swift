import Foundation

/// The queue's version of the field: it moves on with every landed step, own or foreign. Edits name the
/// version they were computed against (``EditTransaction/base``).
public struct FieldVersion: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public var rawValue: Int

    public init(_ rawValue: Int) { self.rawValue = rawValue }

    public var next: FieldVersion { FieldVersion(rawValue + 1) }
    public var description: String { "v\(rawValue)" }

    public static func < (a: FieldVersion, b: FieldVersion) -> Bool { a.rawValue < b.rawValue }
}

/// Text a run or the agent wrote: later edits by the same owner may change it until the user touches it.
public struct OwnedSpan: Sendable, Hashable {
    public var owner: String
    public var span: Span

    public init(owner: String, span: Span) {
        self.owner = owner
        self.span = span
    }
}

/// What the queue believes the field holds, after every write it has issued. On the Mac the window is the whole
/// field (`windowBase` 0, absolute AX positions); on iOS it is the caret-relative `documentContextBefore +
/// AfterInput`, whose absolute offset is unknown (`windowBase` nil). All positions are UTF-16 offsets into
/// `window`.
public struct ShadowDocument: Sendable, Hashable {
    public var window: String
    public var windowBase: Int?
    public var caret: Int
    public var version: FieldVersion
    /// Text written by a run or the agent, by owner.
    public var owned: [OwnedSpan]
    /// Sub-ranges of owned text the user changed: automatic edits touching them conflict (manual-choice
    /// precedence). A zero-length span marks a user deletion.
    public var tainted: [Span]

    public init(
        window: String, windowBase: Int? = nil, caret: Int, version: FieldVersion = FieldVersion(0),
        owned: [OwnedSpan] = [], tainted: [Span] = []
    ) {
        self.window = window
        self.windowBase = windowBase
        self.caret = caret
        self.version = version
        self.owned = owned
        self.tainted = tainted
    }
}

/// One read of the host field, split at the caret (UTF-16). On iOS `before` and `after` are the proxy's
/// `documentContextBefore/AfterInput`: length-limited, so their outer edges move with the caret and with every
/// write; only the caret between them is a fixed point (`windowBase` nil). On the Mac they are the whole field
/// split at the selection (`windowBase` 0, absolute positions).
public struct FieldSnapshot: Sendable, Hashable {
    public var before: String
    public var after: String
    public var windowBase: Int?

    /// The iOS text proxy's view: the text before and after the caret.
    public init(before: String, after: String, windowBase: Int? = nil) {
        self.before = before
        self.after = after
        self.windowBase = windowBase
    }

    /// A whole window with the caret at UTF-16 offset `caret` (clamped to the window).
    public init(window: String, caret: Int, windowBase: Int? = nil) {
        let units = Array(window.utf16)
        let split = min(max(caret, 0), units.count)
        self.init(
            before: String(decoding: units[..<split], as: UTF16.self),
            after: String(decoding: units[split...], as: UTF16.self), windowBase: windowBase)
    }

    public var window: String { before + after }
    public var caret: Int { before.utf16.count }
}
