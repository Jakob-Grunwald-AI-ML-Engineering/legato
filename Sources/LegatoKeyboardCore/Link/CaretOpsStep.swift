import Foundation
import LegatoFieldEdit

/// The planner's edits at the caret (``ProxyOp``: deletes and inserts, as ``ProxyEditPlanner``,
/// ``TypewriterReveal`` and ``DictationVersions/swapOps(to:contextBefore:)`` make them) as one edit queue step:
/// the smallest range replace (``ContiguousPatch``) that turns the text before the caret into what the ops leave.
/// A swap that changes two letters becomes a two-letter patch.
public enum CaretOpsStep {
    public struct Edit: Sendable, Equatable {
        /// UTF-16 offsets into the window that `before` starts.
        public var step: EditStep
        /// Where the caret is once the ops ran: the end of the new text before it.
        public var caret: Int
    }

    /// The step `ops` amount to on a window that starts with `before` (the text before the caret); nil when they
    /// leave it as it was. A delete past the window's start stops there, as the proxy's does.
    public static func edit(for ops: [ProxyOp], before: String) -> Edit? {
        var result = before
        for op in ops {
            switch op {
            case .deleteBackward(let count): result.removeLast(min(count, result.count))
            case .insert(let text): result += text
            }
        }
        guard let step = ContiguousPatch.between(before, result, at: 0) else { return nil }
        return Edit(step: step, caret: result.utf16.count)
    }
}
