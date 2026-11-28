import Foundation
import LegatoCore

/// Gives a meeting's words to the voices the after-meeting diarization found (``SpeakerTimeline``), keeping the people
/// the user knows. Pure: the caller saves the segments and the directory.
///
/// - **Words.** Each word goes to the voice that speaks most while it is spoken. When two voices speak about as much
///   (overlap) the live engine's label decides: the voice most of that label's words went to. A word no voice covers
///   keeps its person. A segment without word times (older meetings) is one unit.
/// - **Splits.** Where the person changes inside a segment it is split at the word; the first part keeps the segment's id
///   (a live board follows segments by id), the others get new ids.
/// - **People.** Each person goes to the voice holding most of their words and keeps id, name and colour. Several people
///   on one voice are merged (reconnect duplicates, over-splits) into the one the user named, else the one with most
///   words; two people the user named differently are never merged. A voice nobody holds becomes a new person
///   (``SpeakerDirectory/split(from:)``) once it has enough words.
/// - **Me.** The user's voice is named "Me" unless the user already named that person.
public enum SpeakerReassignment {
    /// Two voices whose scores on a word are within this share of each other speak equally there. An estimate.
    public static let tieShare: Float = 0.5
    /// How far around a word the timeline is searched when no voice covers it, seconds.
    public static let reach: TimeInterval = 0.25
    /// A different voice for a stretch of words shorter than this, inside one speaker's segment and not clearly louder,
    /// is noise in the word times. An estimate.
    public static let islandSeconds: TimeInterval = 0.3
    /// A voice nobody holds becomes a new person only with at least this many words. An estimate.
    public static let minimumWordsForNewPerson = 20
    public static let userName = "Me"

    public struct Result: Sendable, Equatable {
        public var segments: [MeetingSegment]
        public var directory: SpeakerDirectory
        /// Segments that were split, and the parts that were added by it.
        public var splitSegments: Int
        public var addedSegments: Int
        /// Words now given to someone else than before, merges aside.
        public var movedWords: Int
        public var merges: [SpeakerDirectory.Merge]
        public var newPeople: [PersonID]
        /// The user's person, if one was found.
        public var user: PersonID?
        /// The person each voice was given to.
        public var voicePeople: [Int: PersonID]
    }

    private struct Unit {
        var segment: Int
        var word: Int?
        var start: TimeInterval
        var end: TimeInterval
        var weight: Int
        var original: PersonID?
        var scores: [Float]
        var cluster: Int?
        var decisive = false
    }

    /// - Parameters:
    ///   - user: the voice that is the user (``MeetingSelf/user(micDominant:similarity:)``), if any.
    public static func apply(
        _ timeline: SpeakerTimeline, user: Int?, to segments: [MeetingSegment], directory start: SpeakerDirectory
    ) -> Result {
        var directory = start
        func resolve(_ person: PersonID?) -> PersonID? {
            guard var p = person else { return nil }
            var seen: Set<PersonID> = []
            while let next = directory.merged[p], seen.insert(p).inserted { p = next }
            return p
        }

        // 1. Units and their scores.
        var units: [Unit] = []
        var wordSegments = Set<Int>()
        for (index, segment) in segments.enumerated() {
            let original = resolve(segment.speaker)
            if let words = segment.words, !words.isEmpty, Self.matches(words, segment.text) {
                wordSegments.insert(index)
                for (w, word) in words.enumerated() {
                    units.append(Unit(segment: index, word: w, start: word.start, end: word.end, weight: 1, original: original,
                                      scores: timeline.scores(from: word.start, to: word.end)))
                }
            } else {
                let weight = max(1, segment.text.split(whereSeparator: \.isWhitespace).count)
                units.append(Unit(segment: index, word: nil, start: segment.start, end: segment.end, weight: weight,
                                  original: original, scores: timeline.scores(from: segment.start, to: segment.end)))
            }
        }

        // 2. The clear cases, and the prior of each person from them.
        var prior: [PersonID: [Int: Int]] = [:]
        for i in units.indices {
            var scores = units[i].scores
            // Only a word without a person is placed by the speech around it.
            if (scores.max() ?? 0) <= 0, units[i].original == nil {
                scores = timeline.scores(from: units[i].start - reach, to: units[i].end + reach)
                units[i].scores = scores
            }
            guard let (best, value) = scores.enumerated().max(by: { $0.element < $1.element }).map({ ($0.offset, $0.element) }),
                value > 0
            else { continue }
            let tied = scores.enumerated().filter { $0.offset != best && $0.element >= tieShare * value }
            units[i].cluster = best
            units[i].decisive = tied.isEmpty
            if tied.isEmpty, let person = units[i].original { prior[person, default: [:]][best, default: 0] += units[i].weight }
        }
        let priorVoice = prior.mapValues { counts in counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }!.key }

        // 3. Uncovered words and overlaps follow the live label: its voice when that one speaks about as much as the
        //    loudest; otherwise the word stays with its person (an unclear case does not move a word).
        for i in units.indices where !units[i].decisive {
            guard let original = units[i].original else { continue }
            let prior = priorVoice[original]
            guard let best = units[i].cluster else {
                units[i].cluster = prior
                continue
            }
            let value = units[i].scores[best]
            if let prior, units[i].scores.indices.contains(prior), units[i].scores[prior] >= tieShare * value {
                units[i].cluster = prior
            } else {
                units[i].cluster = nil
            }
        }

        // 4. A short different voice inside one speaker's words, not clearly louder, is noise.
        var start = 0
        while start < units.count {
            var end = start
            while end + 1 < units.count, units[end + 1].segment == units[start].segment { end += 1 }
            if wordSegments.contains(units[start].segment) { smoothIslands(&units, start...end) }
            start = end + 1
        }

        // 5. People to voices.
        var weights: [PersonID: [Int: Int]] = [:]
        var clusterWeight: [Int: Int] = [:]
        var clusterOriginals: [Int: [PersonID: Int]] = [:]
        for unit in units {
            guard let cluster = unit.cluster else { continue }
            clusterWeight[cluster, default: 0] += unit.weight
            if let person = unit.original {
                weights[person, default: [:]][cluster, default: 0] += unit.weight
                clusterOriginals[cluster, default: [:]][person, default: 0] += unit.weight
            }
        }
        var home: [PersonID: Int] = [:]
        for (person, counts) in weights {
            home[person] = counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }!.key
        }
        var owner: [Int: PersonID] = [:]
        var shared: [Int: [PersonID]] = [:]
        var merges: [SpeakerDirectory.Merge] = []
        var newPeople: [PersonID] = []
        for cluster in clusterWeight.keys.sorted() {
            let owners = home.filter { $0.value == cluster }.map(\.key).sorted(by: Self.idOrder)
            if owners.isEmpty {
                guard clusterWeight[cluster, default: 0] >= minimumWordsForNewPerson else { continue }
                let from = clusterOriginals[cluster]?.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
                let person = directory.split(from: from)
                owner[cluster] = person
                newPeople.append(person)
            } else if owners.count == 1 {
                owner[cluster] = owners[0]
            } else {
                let named = owners.filter { directory.isRenamed($0) }
                if named.count >= 2 {
                    shared[cluster] = owners
                    continue
                }
                let target = named.first ?? heaviest(owners, weights, cluster)!
                for other in owners where other != target { merges.append(directory.merge(other, into: target)) }
                owner[cluster] = target
            }
        }

        // 6. Each word's person.
        var assigned: [PersonID?] = units.map { unit in
            guard let cluster = unit.cluster else { return unit.original }
            if let person = owner[cluster] { return person }
            if let people = shared[cluster] {
                if let original = unit.original, people.contains(original) { return original }
                return heaviest(people, weights, cluster)
            }
            return unit.original
        }

        // 7. The user.
        var userPerson: PersonID?
        if let user, let person = owner[user] {
            if !directory.isRenamed(person), let merge = directory.rename(person, to: userName) { merges.append(merge) }
            userPerson = resolve(person)
        }
        assigned = assigned.map(resolve)
        let moved = zip(units, assigned).reduce(0) { $0 + ($1.0.original.map(resolve) == $1.1 ? 0 : $1.0.weight) }

        // 8. Segments, split where the person changes.
        var result: [MeetingSegment] = []
        var splitSegments = 0, added = 0
        var u = 0
        for (index, segment) in segments.enumerated() {
            var range = u..<u
            while range.upperBound < units.count, units[range.upperBound].segment == index { range = range.lowerBound..<(range.upperBound + 1) }
            u = range.upperBound
            guard !range.isEmpty else {
                result.append(segment)
                continue
            }
            guard wordSegments.contains(index), let words = segment.words else {
                var changed = segment
                changed.speaker = assigned[range.lowerBound]
                result.append(changed)
                continue
            }
            var parts: [(person: PersonID?, words: [Int])] = []
            for i in range {
                let word = units[i].word ?? 0
                if let last = parts.last, last.person == assigned[i] {
                    parts[parts.count - 1].words.append(word)
                } else {
                    parts.append((assigned[i], [word]))
                }
            }
            if parts.count > 1 {
                splitSegments += 1
                added += parts.count - 1
            }
            for (p, part) in parts.enumerated() {
                let partWords = part.words.map { words[$0] }
                var piece = segment
                if p > 0 { piece.id = UUID() }
                piece.speaker = part.person
                piece.words = partWords
                piece.text = parts.count == 1 ? segment.text : partWords.map(\.text).joined(separator: " ")
                piece.start = p == 0 ? segment.start : partWords.first!.start
                piece.end = p == parts.count - 1 ? segment.end : partWords.last!.end
                result.append(piece)
            }
        }

        var voicePeople: [Int: PersonID] = [:]
        for (cluster, person) in owner { voicePeople[cluster] = resolve(person) }
        return Result(
            segments: result, directory: directory, splitSegments: splitSegments, addedSegments: added, movedWords: moved,
            merges: merges, newPeople: newPeople.compactMap(resolve), user: userPerson, voicePeople: voicePeople)
    }

    /// The one of `people` with most words on `cluster`; the lowest id among equals.
    private static func heaviest(_ people: [PersonID], _ weights: [PersonID: [Int: Int]], _ cluster: Int) -> PersonID? {
        people.sorted(by: idOrder).max { (weights[$0]?[cluster] ?? 0) < (weights[$1]?[cluster] ?? 0) }
    }

    /// Turns a run of other-voice words back to the voice around it when the run is short and that voice also speaks there.
    private static func smoothIslands(_ units: inout [Unit], _ span: ClosedRange<Int>) {
        var runs: [ClosedRange<Int>] = []
        var i = span.lowerBound
        while i <= span.upperBound {
            var j = i
            while j + 1 <= span.upperBound, units[j + 1].cluster == units[i].cluster { j += 1 }
            runs.append(i...j)
            i = j + 1
        }
        guard runs.count >= 3 else { return }
        for r in 1..<(runs.count - 1) {
            let run = runs[r]
            guard let around = units[runs[r - 1].lowerBound].cluster, around == units[runs[r + 1].lowerBound].cluster,
                let voice = units[run.lowerBound].cluster, voice != around,
                units[run.upperBound].end - units[run.lowerBound].start < islandSeconds,
                run.allSatisfy({ units[$0].scores.indices.contains(around) && units[$0].scores[around] >= 0.5 * units[$0].scores[voice] })
            else { continue }
            for k in run { units[k].cluster = around }
        }
    }

    /// The words are the segment's text (it was not changed since): only then can it be split by them.
    static func matches(_ words: [TranscriptWord], _ text: String) -> Bool {
        words.map(\.text).joined(separator: " ") == text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `P2` before `P10`.
    static func idOrder(_ a: PersonID, _ b: PersonID) -> Bool {
        let na = Int(a.dropFirst()) ?? Int.max, nb = Int(b.dropFirst()) ?? Int.max
        return (na, a) < (nb, b)
    }
}
