/// Legacy composition values remain decodable for historical session logs.
public enum Participant: String, Codable, CaseIterable, Sendable {
    case sentenceAgent, transcriber, segmenter, document, liveAgent, restructureAgent, alternatives, hintBinder, ui, logger
}

public enum SubscriptionBuffer: Sendable {
    case unbounded
    case newest(Int)
}

/// Intercepted consumers receive raw tails and acknowledge segments after processing.
public enum SegmentRouting: Sendable { case automatic, intercepted }
