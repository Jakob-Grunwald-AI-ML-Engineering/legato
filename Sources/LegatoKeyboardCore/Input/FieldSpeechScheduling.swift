import Foundation

/// Shared scheduling policy: while speech is arriving, extend the delivered head and retain only the newest
/// authoritative revision. Rewriting earlier words is background work, released when the take stops.
public enum FieldSpeechScheduling {
    public struct Target: Sendable, Equatable {
        public private(set) var authoritative: [Character] = []
        public private(set) var delivery: [Character] = []
        /// Last canonical text whose end was corroborated. A transient ASR contraction must not move this
        /// frontier backward, otherwise its later re-expansion would append the same heard words twice.
        private var frontier: [Character] = []
        public init() {}
        public var hasDeferredRevision: Bool { authoritative != delivery }

        public mutating func update(_ text: [Character], speaking: Bool) -> [Character] {
            defer { authoritative = text }
            guard speaking, !frontier.isEmpty else { delivery = text; frontier = text; return delivery }
            if text.starts(with: frontier) {
                delivery += text.dropFirst(frontier.count)
                frontier = text
            } else {
                // Find a unique unchanged end, in linear time. Computing a whole-take LCS here would occupy the
                // main actor on every ASR revision even though all actual edit pacing uses asynchronous waits.
                let longest = min(24, max(4, frontier.count / 2))
                var anchored = false
                for length in stride(from: min(longest, frontier.count), through: min(4, frontier.count), by: -1) {
                    let anchor = Array(frontier.suffix(length))
                    if Self.uniqueEnd(of: anchor, in: frontier) == frontier.count,
                       let end = Self.uniqueEnd(of: anchor, in: text) {
                        delivery += text.dropFirst(end)
                        frontier = text
                        anchored = true
                        break
                    }
                }
                // The revision rewrote the frontier's own ending (a comma became a period, a filler went): its last
                // word, corroborated by the words before it, still pins where the delivered words end.
                if !anchored, let end = Self.wordEnd(of: frontier, in: text) {
                    delivery += text.dropFirst(end)
                    frontier = text
                }
            }
            return delivery
        }

        static let corroboratingWords = 3
        private static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        private static func words(_ text: ArraySlice<Character>) -> [(end: Int, word: String)] {
            var result: [(end: Int, word: String)] = []
            var i = text.startIndex
            while i < text.endIndex {
                guard isWord(text[i]) else { i += 1; continue }
                let start = i
                while i < text.endIndex, isWord(text[i]) { i += 1 }
                result.append((i, String(text[start..<i]).lowercased()))
            }
            return result
        }

        /// Where the frontier's last word ends in `text`, compared as words (case and punctuation aside): the only
        /// place it stands after at least `corroboratingWords` of the frontier's words before it, in order. A last
        /// word the revision changed, or one found in several such places, leaves the revision deferred.
        static func wordEnd(of frontier: [Character], in text: [Character]) -> Int? {
            // The frontier's last word, and a few before it: a filler dropped or one word revised still corroborates.
            let tail = words(frontier.suffix(160))
            guard let last = tail.last, tail.count > corroboratingWords,
                  frontier[last.end...].allSatisfy({ !isWord($0) }) else { return nil }
            let before = tail.dropLast().suffix(2 * corroboratingWords).map(\.word)
            let all = words(text[...])
            var found: Int?
            for (j, candidate) in all.enumerated() where candidate.word == last.word {
                let window = all[max(0, j - before.count - 2)..<j].map(\.word)
                guard commonCount(before, window) >= corroboratingWords else { continue }
                guard found == nil else { return nil }
                found = candidate.end
            }
            return found
        }

        /// The length of the longest common subsequence of two short word lists.
        private static func commonCount(_ a: [String], _ b: [String]) -> Int {
            guard !a.isEmpty, !b.isEmpty else { return 0 }
            var row = [Int](repeating: 0, count: b.count + 1)
            for x in a {
                var diagonal = 0
                for (k, y) in b.enumerated() {
                    let up = row[k + 1]
                    row[k + 1] = x == y ? diagonal + 1 : max(row[k + 1], row[k])
                    diagonal = up
                }
            }
            return row[b.count]
        }

        /// KMP search capped at the second match. Repetitive or replaced tails remain deferred, never guessed.
        private static func uniqueEnd(of pattern: [Character], in text: [Character]) -> Int? {
            guard !pattern.isEmpty, pattern.count <= text.count else { return nil }
            var prefix = [Int](repeating: 0, count: pattern.count), matched = 0
            for index in 1..<pattern.count {
                while matched > 0, pattern[index] != pattern[matched] { matched = prefix[matched - 1] }
                if pattern[index] == pattern[matched] { matched += 1 }
                prefix[index] = matched
            }
            var end: Int?
            matched = 0
            for (index, character) in text.enumerated() {
                while matched > 0, character != pattern[matched] { matched = prefix[matched - 1] }
                if character == pattern[matched] { matched += 1 }
                if matched == pattern.count {
                    guard end == nil else { return nil }
                    end = index + 1; matched = prefix[matched - 1]
                }
            }
            return end
        }
    }
}
