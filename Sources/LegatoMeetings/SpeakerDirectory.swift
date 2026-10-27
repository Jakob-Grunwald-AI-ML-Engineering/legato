import Foundation
import LegatoCore

/// The people of one meeting: renaming, merging, and colours. A value type over
/// ``Meeting/speakers``; the caller saves the result and applies any ``Merge`` to the segments and turns.
///
/// - Ids are `P1`, `P2`, …: a new person gets the number after the highest one in use.
/// - A new person is named "Speaker N" (N is the id's number) and takes the lowest colour no one uses.
/// - Renaming to a name someone else already has (ignoring case and surrounding space) **merges** the two.
public struct SpeakerDirectory: Sendable, Equatable {
    /// One person folded into another: every `from` becomes `into`.
    public struct Merge: Sendable, Equatable {
        public var from: PersonID
        public var into: PersonID

        public init(from: PersonID, into: PersonID) {
            self.from = from
            self.into = into
        }

        public func apply(to segments: [MeetingSegment]) -> [MeetingSegment] {
            segments.map { segment in
                guard segment.speaker == from else { return segment }
                var changed = segment
                changed.speaker = into
                return changed
            }
        }

        public func apply(to turns: [SpeakerTurn]) -> [SpeakerTurn] {
            turns.map { turn in
                guard turn.speaker == from else { return turn }
                var changed = turn
                changed.speaker = into
                return changed
            }
        }
    }

    public private(set) var speakers: [PersonID: SpeakerInfo]

    public init(_ speakers: [PersonID: SpeakerInfo] = [:]) { self.speakers = speakers }

    /// Adds a person and returns its id.
    @discardableResult
    public mutating func add() -> PersonID {
        let number = (speakers.keys.compactMap(Self.number).max() ?? 0) + 1
        let id = "P\(number)"
        let used = Set(speakers.values.map(\.colorIndex))
        let color = (0...).first { !used.contains($0) } ?? 0
        speakers[id] = SpeakerInfo(name: Self.defaultName(number), colorIndex: color)
        return id
    }

    /// What the app shows for `id`; nil for a person this meeting does not have.
    public func displayName(of id: PersonID) -> String? { speakers[id]?.name }

    /// Gives `id` a new name. A blank name goes back to "Speaker N". If another person already has that name
    /// the two are merged into that other person, and the merge is returned.
    @discardableResult
    public mutating func rename(_ id: PersonID, to name: String) -> Merge? {
        guard var info = speakers[id] else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = trimmed.isEmpty ? Self.defaultName(Self.number(id) ?? 0) : trimmed
        if !trimmed.isEmpty,
            let other = speakers.first(where: { $0.key != id && Self.same($0.value.name, newName) })?.key
        {
            return merge(id, into: other)
        }
        info.name = newName
        speakers[id] = info
        return nil
    }

    /// Folds `id` into `target`, which keeps its id, name and colour.
    @discardableResult
    public mutating func merge(_ id: PersonID, into target: PersonID) -> Merge {
        let merge = Merge(from: id, into: target)
        guard id != target, speakers.removeValue(forKey: id) != nil, speakers[target] != nil else { return merge }
        return merge
    }

    // MARK: Names

    private static func defaultName(_ number: Int) -> String { "Speaker \(number)" }

    private static func number(_ id: PersonID) -> Int? {
        id.hasPrefix("P") ? Int(id.dropFirst()) : nil
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}
