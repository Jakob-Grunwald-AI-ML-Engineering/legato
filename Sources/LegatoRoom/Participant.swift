public enum Participant: String, Codable, CaseIterable, Sendable {
    case transcriber, segmenter, document, liveAgent, restructureAgent, alternatives, hintBinder, ui, logger
}

public enum SubscriptionBuffer: Sendable {
    case unbounded
    case newest(Int)
}

/// Attach HintBinder before starting audio, then release normal segments with Room.appendSegment.
public enum SegmentRouting: Sendable { case automatic, intercepted }
