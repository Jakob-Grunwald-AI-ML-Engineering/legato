import Foundation

/// Where one streaming dictation take stands, as the Mac's field writer sees it on every poll.
public struct DictationStreamState: Sendable, Equatable {
    /// The cleaned text received so far (only ever grows while the take streams).
    public var text: String
    /// The whole text is here.
    public var isFinal: Bool
    /// The take's cleanup failed after text was streamed: nothing more arrives until the user chooses Retry or
    /// Insert as-is, so the writer leaves the take open and returns.
    public var stalled: Bool
    /// The user chose Retry or Insert as-is: take back what was typed.
    public var retracted: Bool
    public init(text: String, isFinal: Bool, stalled: Bool = false, retracted: Bool = false) {
        self.text = text; self.isFinal = isFinal; self.stalled = stalled; self.retracted = retracted
    }
}
