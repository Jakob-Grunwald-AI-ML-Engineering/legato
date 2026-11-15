import Foundation

/// Mac release policy around the shared speech classifier. The keyboard also uses SpeechDelivery, but may
/// settle a verified revision near its caret; the Mac releases held revisions in confirmed pauses or at stop.
public enum FieldSpeechScheduling {
    public struct Target: Sendable, Equatable {
        private var speech = SpeechDelivery(allowsRevisedTail: false)
        public var authoritative: [Character] { speech.authoritative }
        public var delivery: [Character] { speech.delivered }
        public var hasDeferredRevision: Bool { speech.hasDeferredRevision }
        public init() {}

        public mutating func update(_ text: [Character], speaking: Bool) -> [Character] {
            if speaking { speech.update(text) } else { speech.settle(text) }
            return speech.delivered
        }
    }
}
