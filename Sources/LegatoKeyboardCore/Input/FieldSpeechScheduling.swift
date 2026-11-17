import Foundation

/// Mac release policy around the shared speech classifier. The keyboard also uses SpeechDelivery, but may
/// settle a verified revision near its caret; the Mac releases held revisions in confirmed pauses or at stop.
/// New speech never waits for a held revision: last words heard again as others stay as typed while the words after
/// them go on, and a revision whose delivered end cannot be found goes out with the next text that runs past it.
public enum FieldSpeechScheduling {
    public struct Target: Sendable, Equatable {
        private var speech = SpeechDelivery()
        public var authoritative: [Character] { speech.authoritative }
        public var delivery: [Character] { speech.delivered }
        public var hasDeferredRevision: Bool { speech.hasDeferredRevision }
        public init() {}

        public mutating func update(_ text: [Character], speaking: Bool) -> [Character] {
            guard speaking else { speech.settle(text); return speech.delivered }
            // Holding an unplaceable revision until a pause held every word said after it too (22 s of continuous
            // speech in a recorded take). A contraction (no text past the delivered text) still waits.
            if speech.update(text) == nil, text.count > speech.delivered.count { speech.settle(text) }
            return speech.delivered
        }
    }
}
