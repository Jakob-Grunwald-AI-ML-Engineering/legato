import Testing
import LegatoRoom
import LegatoComposerDoc

func segmentText(_ event: Envelope?) throws -> String {
    let event = try #require(event)
    #expect(event.channel == .asrSegment)
    return try #require(event.payload["words"]).decode([Word].self).map(\.text).joined(separator: " ")
}
