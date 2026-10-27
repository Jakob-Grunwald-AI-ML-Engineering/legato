import Foundation
import LegatoCore

/// The people of one meeting: renaming, merging, colours and "Mark as You". A value type over
/// ``Meeting/speakers``; the caller saves the result and applies any ``Merge`` to the segments and turns.
///
/// - Ids are `P1`, `P2`, …: a new person gets the number after the highest one in use.
/// - A new person is named "Speaker N" (N is the id's number) and takes the lowest colour no one uses.
/// - Renaming to a name someone else already has (ignoring case and surrounding space) **merges** the two.
/// - Only one person is You. Marking someone else moves the flag, and the previous You is called "Speaker N" again.
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
    public mutating func add(isYou: Bool = false) -> PersonID {
        let number = (speakers.keys.compactMap(Self.number).max() ?? 0) + 1
        let id = "P\(number)"
        let used = Set(speakers.values.map(\.colorIndex))
        let color = (0...).first { !used.contains($0) } ?? 0
        speakers[id] = SpeakerInfo(name: isYou ? "You" : Self.defaultName(number), colorIndex: color, isYou: isYou)
        if isYou { markAsYou(id) }
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

    /// Folds `id` into `target`, which keeps its id, name and colour (and is You if either was; a target still
    /// called "Speaker N" is then called "You").
    @discardableResult
    public mutating func merge(_ id: PersonID, into target: PersonID) -> Merge {
        let merge = Merge(from: id, into: target)
        guard id != target, let gone = speakers.removeValue(forKey: id), speakers[target] != nil else { return merge }
        if gone.isYou {
            let defaultNamed = speakers[target]?.name == Self.defaultName(Self.number(target) ?? 0)
            if defaultNamed { markAsYou(target) } else { speakers[target]?.isYou = true }
        }
        return merge
    }

    /// Makes `id` the user: named "You", and no one else is You.
    public mutating func markAsYou(_ id: PersonID) {
        guard speakers[id] != nil else { return }
        for other in speakers.keys where other != id && speakers[other]?.isYou == true {
            speakers[other]?.isYou = false
            if speakers[other]?.name == "You" { speakers[other]?.name = Self.defaultName(Self.number(other) ?? 0) }
        }
        speakers[id]?.isYou = true
        speakers[id]?.name = "You"
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
