import Foundation
import LegatoCore

/// Gives a meeting's words to the voices the after-meeting diarization found (``SpeakerTimeline``), keeping the people
/// the user knows. Pure: the caller saves the segments and the directory.
///
/// - **Words.** Each word goes to the voice that speaks most while it is spoken. When two voices speak about as much
///   (overlap) the live engine's label decides: the voice most of that label's words went to. A word no voice covers
///   keeps its person. A segment without word times (older meetings) is one unit.
/// - **The user alone on the microphone** (the Mac, ``Evidence``): a word clearly louder on the microphone is the user's
///   where the user's voice is heard at all, whichever voice the diarization put first, and a word clearly louder on the
///   system audio is never the user's. The diarization may split one voice in two; the tracks do not.
/// - **Splits.** Where the person changes inside a segment it is split at the word; the first part keeps the segment's id
///   (a live board follows segments by id), the others get new ids. The live engine heard one speaker there, and its
///   segment edges are more exact than the diarization's, so a change must hold: a part shorter than
///   ``minimumRunWords`` words or ``minimumRunSeconds`` joins its neighbours, unless the tracks confirm it (a barge-in
///   from the other side, ``bargeInSeconds``) or, without tracks, the neighbours' voices are silent through it.
/// - **People.** Each person goes to the voice holding most of their words and keeps id, name and colour. Several people
///   on one voice are merged (reconnect duplicates, over-splits) into the one the user named, else the one with most
///   words; two people the user named differently are never merged. A voice nobody holds becomes a new person
///   (``SpeakerDirectory/split(from:)``) once it has enough words, unless it sounds like a voice someone holds
///   (``duplicateSimilarity``, on the same track): then it is that voice split in two by the diarization.
/// - **Me.** The user's voice is named "Me" unless the user already named that person.
public enum SpeakerReassignment {
    /// Two voices whose scores on a word are within this share of each other speak equally there. An estimate.
    public static let tieShare: Float = 0.5
    /// How far around a word the timeline is searched when no voice covers it, seconds.
    public static let reach: TimeInterval = 0.25
    /// Inside one segment a change of person holds when its part has at least this many words and lasts at least
    /// this long, seconds; shorter parts join their neighbours unless the tracks confirm them. Estimates, measured with
    /// `legato meetings speakers --replay`: on three real Mac meetings most changes inside a segment were 1–2 words
    /// under a second, on the same track, and their parts read as one sentence.
    public static let minimumRunWords = 3
    public static let minimumRunSeconds: TimeInterval = 1
    /// A shorter part the tracks confirm (a barge-in from the other side) must last this long until the next part
    /// begins, seconds: the live engine times many words at 60 ms, too short to compare the tracks over. An estimate.
    public static let bargeInSeconds: TimeInterval = 0.3
    /// Without tracks a shorter part holds when it has this many words and the neighbours' voices speak at most
    /// ``cleanShare`` of its voice through it: a clean interjection. Estimates.
    public static let cleanRunWords = 2
    public static let cleanShare: Float = 0.1
    /// A voice nobody holds becomes a new person only with at least this many words. An estimate.
    public static let minimumWordsForNewPerson = 20
    /// A voice nobody holds that is at least this similar (cosine of the centroids) to a voice someone holds is that
    /// voice split by the diarization, not a new person. An estimate: on real Mac meetings distinct people scored up to
    /// 0.59, the fragment the replay found 0.62.
    public static let duplicateSimilarity: Float = 0.6
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

    /// What else the cleanup knows beside the timeline.
    public struct Evidence: Sendable {
        /// Which track each span is clearly louder on (``MeetingSelf/side(micPower:systemPower:)``); nil without both
        /// tracks (the iPhone).
        public var side: (@Sendable (TimeInterval, TimeInterval) -> MeetingSelf.Side?)?
        /// Per voice, whether it is the microphone's (``MeetingSelf/isMicDominant(_:)``); nil without both tracks.
        public var micDominant: [Int: Bool]?
        /// How alike the voices sound: the cosine similarity of their centroids, `[voice][voice]`; empty when unknown.
        public var voiceSimilarity: [[Float]]

        public init(
            side: (@Sendable (TimeInterval, TimeInterval) -> MeetingSelf.Side?)? = nil, micDominant: [Int: Bool]? = nil,
            voiceSimilarity: [[Float]] = []
        ) {
            self.side = side
            self.micDominant = micDominant
            self.voiceSimilarity = voiceSimilarity
        }
    }

    private struct Unit {
        var segment: Int
        var word: Int?
        var start: TimeInterval
        var end: TimeInterval
        var weight: Int
        var original: PersonID?
        var scores: [Float]
        var side: MeetingSelf.Side?
        var cluster: Int?
        var decisive = false
    }

    /// - Parameters:
    ///   - user: the voice that is the user (``MeetingSelf/user(micDominant:similarity:)``), if any.
    public static func apply(
        _ timeline: SpeakerTimeline, user: Int?, to segments: [MeetingSegment], directory start: SpeakerDirectory,
        evidence: Evidence = Evidence()
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
                                      scores: timeline.scores(from: word.start, to: word.end), side: evidence.side?(word.start, word.end)))
                }
            } else {
                let weight = max(1, segment.text.split(whereSeparator: \.isWhitespace).count)
                units.append(Unit(segment: index, word: nil, start: segment.start, end: segment.end, weight: weight,
                                  original: original, scores: timeline.scores(from: segment.start, to: segment.end),
                                  side: evidence.side?(segment.start, segment.end)))
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

        // 4. The user alone on the microphone: the tracks decide between the user and everyone else. A word loud on the
        //    microphone is the user's only where the user's voice is heard at all: a quiet microphone under a silent
        //    system track (a cough, typing, a word's time a little off) is not speech of the user's.
        if let user, let micDominant = evidence.micDominant, micDominant.filter(\.value).map(\.key) == [user] {
            for i in units.indices {
                switch units[i].side {
                case .mic? where units[i].scores.indices.contains(user) && units[i].scores[user] > 0:
                    units[i].cluster = user
                    units[i].decisive = true
                case .system? where units[i].cluster == user || units[i].cluster == nil:
                    // Not the user's: the loudest other voice heard; without one it is unclear and the live label decides.
                    units[i].cluster = units[i].scores.enumerated().filter { $0.offset != user && $0.element > 0 }
                        .max { $0.element < $1.element }?.offset
                default: break
                }
            }
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
        var unheld: [Int] = []
        for cluster in clusterWeight.keys.sorted() {
            let owners = home.filter { $0.value == cluster }.map(\.key).sorted(by: Self.idOrder)
            if owners.isEmpty {
                unheld.append(cluster)
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
        // A voice nobody holds: a fragment of a held voice it sounds like (never the user's, never across the tracks),
        // else a new person once it has enough words (the user's voice always: the tracks or the profile found it).
        let held = Set(owner.keys).subtracting(user.map { [$0] } ?? [])
        for cluster in unheld {
            if cluster != user, let twin = Self.twin(of: cluster, among: held, evidence) {
                owner[cluster] = owner[twin]
                continue
            }
            guard cluster == user || clusterWeight[cluster, default: 0] >= minimumWordsForNewPerson else { continue }
            let from = clusterOriginals[cluster]?.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
            let person = directory.split(from: from)
            owner[cluster] = person
            newPeople.append(person)
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

        // 7. A change of person inside a segment must hold.
        var first = 0
        while first < units.count {
            var last = first
            while last + 1 < units.count, units[last + 1].segment == units[first].segment { last += 1 }
            if wordSegments.contains(units[first].segment) { holdChanges(&assigned, units, first...last, tracks: evidence.side != nil) }
            first = last + 1
        }

        // 8. The user.
        var userPerson: PersonID?
        if let user, let person = owner[user] {
            if !directory.isRenamed(person), let merge = directory.rename(person, to: userName) { merges.append(merge) }
            userPerson = resolve(person)
        }
        assigned = assigned.map(resolve)
        let moved = zip(units, assigned).reduce(0) { $0 + ($1.0.original.map(resolve) == $1.1 ? 0 : $1.0.weight) }

        // 9. Segments, split where the person changes.
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

    /// The held voice most like `cluster`, when it is at least ``duplicateSimilarity`` alike and on the same track.
    private static func twin(of cluster: Int, among held: Set<Int>, _ evidence: Evidence) -> Int? {
        guard evidence.voiceSimilarity.indices.contains(cluster) else { return nil }
        let row = evidence.voiceSimilarity[cluster]
        let mic = evidence.micDominant
        return held.filter { row.indices.contains($0) && row[$0] >= duplicateSimilarity && mic?[$0] == mic?[cluster] }
            .max { (row[$0], -$0) < (row[$1], -$1) }
    }

    /// Inside one segment (`span` of `units`): parts of another person that do not hold join their neighbours, the
    /// shortest first. A part holds when it is long enough (``minimumRunWords``, ``minimumRunSeconds``); when its track
    /// differs from a neighbour's for long enough (a barge-in from the other side, ``bargeInSeconds``); or, without
    /// `tracks`, when it is a clean interjection (``cleanRunWords``, ``cleanShare``).
    private static func holdChanges(_ assigned: inout [PersonID?], _ units: [Unit], _ span: ClosedRange<Int>, tracks: Bool) {
        func parts() -> [ClosedRange<Int>] {
            var result: [ClosedRange<Int>] = []
            var i = span.lowerBound
            while i <= span.upperBound {
                var j = i
                while j + 1 <= span.upperBound, assigned[j + 1] == assigned[i] { j += 1 }
                result.append(i...j)
                i = j + 1
            }
            return result
        }
        func seconds(_ part: ClosedRange<Int>) -> TimeInterval { units[part.upperBound].end - units[part.lowerBound].start }
        func side(_ part: ClosedRange<Int>) -> MeetingSelf.Side? {
            let mic = part.filter { units[$0].side == .mic }.count, system = part.filter { units[$0].side == .system }.count
            return mic > system ? .mic : system > mic ? .system : nil
        }
        func voice(_ part: ClosedRange<Int>) -> Int? {
            var counts: [Int: Int] = [:]
            for k in part { if let c = units[k].cluster { counts[c, default: 0] += 1 } }
            return counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
        }
        func score(_ voice: Int, over part: ClosedRange<Int>) -> Float {
            part.reduce(0) { $0 + (units[$1].scores.indices.contains(voice) ? units[$1].scores[voice] : 0) }
        }
        while true {
            let all = parts()
            guard all.count > 1 else { return }
            func holds(_ r: Int) -> Bool {
                let part = all[r]
                if part.count >= minimumRunWords && seconds(part) >= minimumRunSeconds { return true }
                let neighbours = [r - 1, r + 1].filter(all.indices.contains).map { all[$0] }
                // The live engine times a short word as briefly as 60 ms; the tracks are judged over the time until
                // the next part begins.
                let extent = (r + 1 < all.count ? units[all[r + 1].lowerBound].start : units[part.upperBound].end) - units[part.lowerBound].start
                if extent >= bargeInSeconds, let mine = side(part), neighbours.contains(where: { side($0).map { $0 != mine } ?? false }) {
                    return true
                }
                if !tracks, part.count >= cleanRunWords, let mine = voice(part) {
                    let own = score(mine, over: part)
                    let others = neighbours.compactMap(voice).filter { $0 != mine }
                    if own > 0, !others.isEmpty, others.allSatisfy({ score($0, over: part) <= cleanShare * own }) { return true }
                }
                return false
            }
            guard let r = all.indices.filter({ !holds($0) }).min(by: { (seconds(all[$0]), all[$0].count, $0) < (seconds(all[$1]), all[$1].count, $1) })
            else { return }
            // Into the neighbours when they are one person, else the one with more of the segment's words.
            let neighbours = [r - 1, r + 1].filter(all.indices.contains).map { assigned[all[$0].lowerBound] }
            let counts = neighbours.map { p in span.filter { assigned[$0] == p }.count }
            let target = neighbours[counts.indices.max { counts[$0] < counts[$1] }!]
            for k in all[r] { assigned[k] = target }
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
