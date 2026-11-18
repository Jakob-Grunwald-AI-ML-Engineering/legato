import Foundation
import LegatoKeyboardCore

/// One exact native-field plan. The expensive diff is built once; verified writes advance its expected text.
/// One step per hunk: a replacement is one write, so old graphemes stay until their replacement is in.
struct NativeEditPlan: Sendable {
    struct Step: Sendable, Equatable {
        var range: Range<Int>
        var replacement: [Character]
    }
    let desired: [Character]
    private(set) var expected: [Character]
    private let steps: [Step]
    private var index = 0

    init(current: [Character], desired: [Character]) {
        self.expected = current; self.desired = desired
        var steps: [Step] = [], shift = 0
        for change in FieldEditCoordinator.changes(from: current, to: desired) {
            let start = change.start + shift, removed = change.end - change.start
            // A hunk is one chunk: its deletes and inserts go out together at one place; how its insert enters the field
            // (`ChunkEntrance` pieces) is the executor's business.
            steps.append(Step(range: start..<(start + removed), replacement: change.text))
            shift += change.text.count - removed
        }
        self.steps = steps
    }

    var next: Step? { index < steps.count ? steps[index] : nil }
    var afterNext: [Character]? {
        guard let next else { return nil }
        var after = expected
        after.replaceSubrange(next.range, with: next.replacement)
        return after
    }
    func matches(current: [Character], desired: [Character]) -> Bool {
        expected == current && self.desired == desired
    }
    /// Only independently read-back text advances the cached plan. A mismatch forces its owner to replan.
    @discardableResult mutating func confirm(_ observed: [Character]) -> Bool {
        guard next != nil, afterNext == observed else { return false }
        expected = observed
        index += 1
        return true
    }
}
