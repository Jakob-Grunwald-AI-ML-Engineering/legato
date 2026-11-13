import Foundation
import LegatoKeyboardCore

/// One exact native-field plan. The expensive diff is built once; verified writes advance its expected text.
/// Atomic replacement pairs preserve old graphemes until their replacements are ready, including on interruption.
struct NativeEditPlan: Sendable {
    struct Step: Sendable, Equatable {
        var range: Range<Int>
        var replacement: [Character]
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
            if !paced || change.text.isEmpty {
                steps.append(Step(range: start..<(start + removed), replacement: change.text))
            } else {
                let paired = min(removed, change.text.count)
                for i in 0..<paired {
                    steps.append(Step(range: (start + i)..<(start + i + 1), replacement: [change.text[i]]))
                }
                // Only genuinely deleted old characters remain after all ready replacements were paired.
                if removed > paired { steps.append(Step(range: (start + paired)..<(start + removed), replacement: [])) }
                if change.text.count > paired {
                    for i in paired..<change.text.count {
                        steps.append(Step(range: (start + i)..<(start + i), replacement: [change.text[i]]))
                    }
                }
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
