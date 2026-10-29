import Foundation

/// Which side of text inserted exactly at a position that position stays on.
public enum Bias: Sendable, Hashable, Codable {
    case before, after
}

/// How a landed step moves the field's positions: `span` (before the step) became `insertedLength` units.
public struct StepMap: Sendable, Hashable {
    public var span: Span
    public var insertedLength: Int

    public init(span: Span, insertedLength: Int) {
        self.span = span
        self.insertedLength = insertedLength
    }

    public init(_ step: EditStep) {
        self.init(span: step.span, insertedLength: step.text.utf16.count)
    }

    /// A pending span after the step: `moved` (unchanged before it, shifted after it), or `deleted` when the step
    /// replaced text inside it or it inside the step.
    public enum Mapped: Sendable, Hashable {
        case moved(Span)
        case deleted
    }

    /// The net length change.
    public var delta: Int { insertedLength - span.length }

    /// `pending` after the step. `bias` places an insertion point that sits exactly where the step inserted.
    public func map(_ pending: Span, bias: Bias = .before) -> Mapped {
        if pending.isEmpty {
            let p = pending.location
            guard !(span.location < p && p < span.end) else { return .deleted }
            return .moved(.at(map(position: p, bias: bias)))
        }
        if pending.end <= span.location { return .moved(pending) }
        if pending.location >= span.end {
            return .moved(Span(location: pending.location + delta, length: pending.length))
        }
        return .deleted
    }

    /// A position after the step; one inside the replaced range collapses to the side `bias` names.
    public func map(position p: Int, bias: Bias = .before) -> Int {
        if p < span.location { return p }
        if p > span.end { return p + delta }
        if p == span.end, !span.isEmpty { return span.location + insertedLength }
        return bias == .before ? span.location : span.location + insertedLength
    }

    /// A range that stretches or shrinks with the step instead of being deleted (owned and tainted text);
    /// text inserted at its edges stays outside it. Nil once nothing of it is left.
    func adjust(_ range: Span) -> Span? {
        if range.isEmpty { return .at(map(position: range.location, bias: .before)) }
        let start = map(position: range.location, bias: .after)
        let end = map(position: range.end, bias: .before)
        return end > start ? Span(location: start, length: end - start) : nil
    }
}
