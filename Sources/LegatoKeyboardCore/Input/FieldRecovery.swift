import Foundation

/// Shared recovery policy. Transports acquire fresh, bounded evidence and restore the user's cursor; this state
/// decides whether unchanged targets can be relocated and their exact edits replanned. It never sends input.
public struct FieldRecovery: Sendable {
    public static let lookAroundChars = 1_024
    public static let budgetMs = 2_500.0
    public static let maxAttempts = 1

    /// Start close to the caret. A short target never needs a full 1,024-character walk in both directions.
    public static func nearbyLimit(for request: Request) -> Int {
        min(lookAroundChars, max(192, request.targets.map {
            max($0.expected.count, $0.landed?.count ?? 0) + $0.before.count + $0.after.count + 64
        }.max() ?? 192))
    }

    public func canResolve(_ request: Request, text: String, completeDocument: Bool = false) -> Bool {
        resolve(request, text: text, generation: request.generation, revision: request.revision,
                restored: true, completeDocument: completeDocument).allSatisfy {
            if case .replan = $0 { return true }; return false
        }
    }

    public struct Target: Sendable, Equatable {
        public var id: String
        public var expected: String
        /// A known result of an uncertain operation. It is accepted only if fresh evidence actually shows it.
        public var landed: String?
        public var before: String
        public var after: String
        public init(id: String, expected: String, landed: String? = nil, before: String = "", after: String = "") {
            self.id = id; self.expected = expected; self.landed = landed; self.before = before; self.after = after
        }
    }
    public struct Request: Sendable, Equatable {
        public let id: UInt64
        public let generation: String
        public let revision: UInt64
        public let targets: [Target]
    }
    public enum Refusal: String, Sendable, Equatable { case cancelled, unrestored, unreadable, changed, ambiguous, uncorroborated }
    public struct Placement: Sendable, Equatable {
        public let id: String
        /// Grapheme offsets within the supplied evidence, never an assertion about the whole document.
        public let range: Range<Int>
        public let text: String
    }
    public enum Decision: Sendable, Equatable { case replan(Placement), stop(id: String, Refusal) }
    private var sequence: UInt64 = 0
    private var attempted: [String] = []
    public init() {}

    public mutating func begin(generation: String, revision: UInt64, targets: [Target]) -> Request? {
        guard !targets.isEmpty else { return nil }
        let signature = generation + ":" + String(revision) + ":" + targets.map { $0.id + "=" + $0.expected }.joined(separator: "|")
        guard attempted.filter({ $0 == signature }).count < Self.maxAttempts else { return nil }
        attempted.append(signature)
        if attempted.count > 64 { attempted.removeFirst() }
        sequence &+= 1
        return Request(id: sequence, generation: generation, revision: revision, targets: targets)
    }

    public func resolve(_ request: Request, text: String, generation: String, revision: UInt64,
                        restored: Bool, completeDocument: Bool = false) -> [Decision] {
        func stop(_ reason: Refusal) -> [Decision] { request.targets.map { .stop(id: $0.id, reason) } }
        guard generation == request.generation, revision == request.revision else { return stop(.cancelled) }
        guard restored else { return stop(.unrestored) }
        guard !text.isEmpty else { return stop(.unreadable) }
        let chars = Array(text)
        return request.targets.map { target in
            let candidates = [target.expected, target.landed].compactMap { $0 }
            var placements: [Placement] = []
            // Bounded-window uniqueness needs unchanged surrounding evidence; a coincident repeated word alone is
            // never enough. A complete desktop read can prove uniqueness without surrounding anchors.
            guard completeDocument || target.before.count + target.after.count >= 8 else {
                return .stop(id: target.id, .uncorroborated)
            }
            for candidate in Set(candidates) {
                let needle = Array(candidate), before = Array(target.before), after = Array(target.after)
                let pattern = before + needle + after
                for start in Self.occurrences(of: pattern, in: chars) {
                    let at = start + before.count
                    placements.append(Placement(id: target.id, range: at..<(at + needle.count), text: candidate))
                    if placements.count > 1 { return .stop(id: target.id, .ambiguous) }
                }
            }
            guard let placement = placements.first else { return .stop(id: target.id, .changed) }
            return .replan(placement)
        }
    }
    /// Linear grapheme search, stopping at the second occurrence. Long repetitive documents must not turn a
    /// bounded read into quadratic work, and UTF-16 substring matches must not split an emoji or combining cluster.
    private static func occurrences(of pattern: [Character], in text: [Character]) -> [Int] {
        guard !pattern.isEmpty else { return text.isEmpty ? [0] : [0, 1] }
        guard pattern.count <= text.count else { return [] }
        var prefix = [Int](repeating: 0, count: pattern.count), matched = 0
        for i in 1..<pattern.count {
            while matched > 0, pattern[i] != pattern[matched] { matched = prefix[matched - 1] }
            if pattern[i] == pattern[matched] { matched += 1 }
            prefix[i] = matched
        }
        matched = 0
        var found: [Int] = []
        for (i, character) in text.enumerated() {
            while matched > 0, character != pattern[matched] { matched = prefix[matched - 1] }
            if character == pattern[matched] { matched += 1 }
            if matched == pattern.count {
                found.append(i + 1 - pattern.count)
                if found.count == 2 { break }
                matched = prefix[matched - 1]
            }
        }
        return found
    }

}
