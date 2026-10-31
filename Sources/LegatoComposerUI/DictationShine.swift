import Foundation
import LegatoComposerDoc

/// A fresh mount establishes a baseline; reopening the keyboard never replays its old commit.
struct DictationShineAdmission {
    private(set) var active: DictationCommit?
    private var lastSequence: Int?
    mutating func baseline(_ commit: DictationCommit?) { lastSequence = commit?.sequence; active = nil }
    mutating func accept(_ commit: DictationCommit?, now: Double = ProcessInfo.processInfo.systemUptime) {
        guard let commit else { active = nil; return }
        guard commit.sequence != lastSequence else { return }
        lastSequence = commit.sequence
        let age = now - commit.uptime
        active = age.isFinite && age >= 0 && age <= 1 ? commit : nil
    }
}

struct DictationShinePlan: Equatable {
    static let duration = 0.64
    var sequence: Int
    var ranks: [String: Int]
    var count: Int
    init?(_ commit: DictationCommit?, words: [Word], now: Double = ProcessInfo.processInfo.systemUptime) {
        guard let commit, (0...1).contains(now - commit.uptime) else { return nil }
        let accepted = Array(commit.wordIDs.suffix(DictationCommit.maximumWords))
        let visible = Set(words.map(\.id))
        var ranks: [String: Int] = [:]
        for (rank, id) in accepted.enumerated() where visible.contains(id) { ranks[id] = rank }
        guard !ranks.isEmpty else { return nil }
        self.sequence = commit.sequence; self.ranks = ranks; count = accepted.count
    }
    func progress(for wordID: String, overall: Double) -> Double? {
        guard let rank = ranks[wordID] else { return nil }
        let delay = 0.22 * Double(rank) / Double(max(1, count - 1))
        return min(1, max(0, (overall * Self.duration - delay) / 0.42))
    }
}
