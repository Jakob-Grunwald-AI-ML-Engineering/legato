import Foundation
@testable import LegatoPostProcessing

/// What one cleaned transcript earned against its fixture.
struct CleanupScore: Codable, Sendable, Equatable {
    var mustContainHits: Int
    var mustContainTotal: Int
    /// The forbidden terms found in the output.
    var violations: [String]
    /// No chunk was rejected by the guard and the whole output stays within it.
    var guardAccepted: Bool
    /// Word edit distance to the reference, ignoring case and punctuation.
    var editDistance: Int
    /// The same, with case kept: a missing capital counts.
    var casedEditDistance: Int
    var referenceTokens: Int
    /// Every required term present, no forbidden term, guard accepted.
    var passed: Bool
}

enum CleanupScorer {
    /// Runs of letters and digits; punctuation and symbols separate tokens and are dropped.
    static func tokens(_ text: String, caseSensitive: Bool) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in caseSensitive ? text : text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Levenshtein distance over words.
    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0 ... b.count)
        for i in 1 ... a.count {
            var row = [i] + [Int](repeating: 0, count: b.count)
            for j in 1 ... b.count {
                row[j] = min(previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1), previous[j] + 1, row[j - 1] + 1)
            }
            previous = row
        }
        return previous[b.count]
    }

    /// Scores `output`, the text the cleanup stage kept for `input`.
    ///
    /// - Parameters:
    ///   - input: the text the stage was given (after inverse text normalization), which the guard compares to.
    ///   - rejectedChunks: how many chunks the stage's guard rejected on the way.
    static func score(
        output: String, input: String, fixture: CleanupFixture, rejectedChunks: Int,
        cleanupGuard: CleanupGuard = CleanupGuard()
    ) -> CleanupScore {
        let hits = fixture.mustContain.filter { output.contains($0) }.count
        let violations = fixture.mustNotContain.filter { output.contains($0) }
        let guardAccepted = rejectedChunks == 0 && cleanupGuard.accepts(output, reference: input)
        let reference = tokens(fixture.reference, caseSensitive: false)
        let distance = editDistance(tokens(output, caseSensitive: false), reference)
        let casedDistance = editDistance(
            tokens(output, caseSensitive: true), tokens(fixture.reference, caseSensitive: true))
        return CleanupScore(
            mustContainHits: hits, mustContainTotal: fixture.mustContain.count, violations: violations,
            guardAccepted: guardAccepted, editDistance: distance, casedEditDistance: casedDistance,
            referenceTokens: reference.count,
            passed: hits == fixture.mustContain.count && violations.isEmpty && guardAccepted)
    }
}

/// One fixture run through a prompt variant and a model.
struct CleanupCaseResult: Codable, Sendable, Equatable {
    var name: String
    var output: String
    /// The model's raw replies, one per chunk.
    var replies: [String]
    var latencySeconds: Double
    var score: CleanupScore
}

/// The numbers one variant × model earned over a fixture split.
struct CleanupSummary: Sendable, Equatable {
    var fixtures: Int
    var passed: Int
    var passRate: Double
    var mustContainRecall: Double
    var violations: Int
    /// Fixtures in which the guard rejected a chunk or the output.
    var guardRejections: Int
    var meanLatencySeconds: Double
    /// Edit distance over reference tokens, ignoring case.
    var wer: Double
    /// The same with case kept.
    var casedWer: Double

    init(results: [CleanupCaseResult]) {
        let scores = results.map(\.score)
        fixtures = results.count
        passed = scores.filter(\.passed).count
        passRate = Self.ratio(passed, fixtures)
        mustContainRecall = Self.ratio(scores.map(\.mustContainHits).reduce(0, +), scores.map(\.mustContainTotal).reduce(0, +))
        violations = scores.map(\.violations.count).reduce(0, +)
        guardRejections = scores.filter { !$0.guardAccepted }.count
        meanLatencySeconds = results.isEmpty ? 0 : results.map(\.latencySeconds).reduce(0, +) / Double(results.count)
        let referenceTokens = scores.map(\.referenceTokens).reduce(0, +)
        wer = Self.ratio(scores.map(\.editDistance).reduce(0, +), referenceTokens)
        casedWer = Self.ratio(scores.map(\.casedEditDistance).reduce(0, +), referenceTokens)
    }

    private static func ratio(_ part: Int, _ whole: Int) -> Double { whole == 0 ? 0 : Double(part) / Double(whole) }
}

/// A prompt variant run against one model on one split.
struct CleanupEvalRun: Codable, Sendable, Equatable {
    var variant: String
    var model: String
    var split: String
    var results: [CleanupCaseResult]
}

enum CleanupEvalReport {
    static func json(runs: [CleanupEvalRun]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(runs)
    }

    static func markdown(runs: [CleanupEvalRun]) -> String {
        var lines = [
            "| variant | model | split | pass | must-contain recall | violations | guard rejections | mean latency (s) | WER | cased WER |",
            "|---|---|---|---|---|---|---|---|---|---|",
        ]
        for run in runs {
            let s = CleanupSummary(results: run.results)
            lines.append(
                "| \(run.variant) | \(run.model) | \(run.split) | \(s.passed)/\(s.fixtures) (\(percent(s.passRate, 0))) "
                    + "| \(percent(s.mustContainRecall, 0)) | \(s.violations) | \(s.guardRejections) "
                    + "| \(String(format: "%.2f", s.meanLatencySeconds)) | \(percent(s.wer, 1)) | \(percent(s.casedWer, 1)) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func percent(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f%%", value * 100)
    }
}
