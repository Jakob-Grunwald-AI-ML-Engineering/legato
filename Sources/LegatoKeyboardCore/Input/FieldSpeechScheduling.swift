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
                for length in stride(from: min(longest, frontier.count), through: min(4, frontier.count), by: -1) {
                    let anchor = Array(frontier.suffix(length))
                    if Self.uniqueEnd(of: anchor, in: frontier) == frontier.count,
                       let end = Self.uniqueEnd(of: anchor, in: text) {
                        delivery += text.dropFirst(end)
                        frontier = text
                        break
                    }
                }
            }
            return delivery
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
