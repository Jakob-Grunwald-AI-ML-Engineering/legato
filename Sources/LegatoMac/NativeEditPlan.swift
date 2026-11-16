import Foundation
import LegatoKeyboardCore

/// One exact native-field plan. The expensive diff is built once; verified writes advance its expected text.
/// One step per hunk: a replacement is one write, so old graphemes stay until their replacement is in.
struct NativeEditPlan: Sendable {
    struct Step: Sendable, Equatable {
        var range: Range<Int>
        var replacement: [Character]
        /// One grapheme of new speech at the end of the text, typed at the typewriter pace. Every other step is a whole hunk.
        var typewriter = false
    }
    let desired: [Character]
    let paced: Bool
    private(set) var expected: [Character]
    private let steps: [Step]
    private var index = 0
    private(set) var remainingInsertions: Int

    init(current: [Character], desired: [Character], paced: Bool) {
        self.expected = current; self.desired = desired; self.paced = paced
        var steps: [Step] = [], shift = 0
        for change in FieldEditCoordinator.changes(from: current, to: desired) {
            let start = change.start + shift, removed = change.end - change.start
            // A hunk is one chunk: its deletes and inserts go out together at one place. Only new speech appended at the
            // end of the text is typed grapheme by grapheme (the typewriter).
            if paced, removed == 0, change.end == current.count, change.text.count > 1 {
                for i in 0..<change.text.count {
                    steps.append(Step(range: (start + i)..<(start + i), replacement: [change.text[i]], typewriter: true))
                }
            } else {
                steps.append(Step(range: start..<(start + removed), replacement: change.text))
            }
            shift += change.text.count - removed
        }
        self.steps = steps
        remainingInsertions = steps.reduce(0) { $0 + $1.replacement.count }
    }

    var next: Step? { index < steps.count ? steps[index] : nil }
    var afterNext: [Character]? {
        guard let next else { return nil }
        var after = expected
        after.replaceSubrange(next.range, with: next.replacement)
        return after
    }
    func matches(current: [Character], desired: [Character], paced: Bool) -> Bool {
        expected == current && self.desired == desired && self.paced == paced
    }
    /// Only independently read-back text advances the cached plan. A mismatch forces its owner to replan.
    @discardableResult mutating func confirm(_ observed: [Character]) -> Bool {
        guard let step = next, afterNext == observed else { return false }
        expected = observed
        remainingInsertions -= step.replacement.count
        index += 1
        return true
    }
}
