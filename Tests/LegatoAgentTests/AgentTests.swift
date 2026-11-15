import Testing
import LegatoClaude
import LegatoRoom
@testable import LegatoAgent

@Test func streamingFramesAndConfidenceMarks() throws {
    var parser = SSEParser()
    #expect(parser.consume(line: "event: content_block_delta") == nil)
    #expect(parser.consume(line: #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"hello"}}"#) == nil)
    #expect(parser.consume(line: "")?.event == "content_block_delta")
    #expect(DocPresenter.strip("Keep ⟨Claude|0.42⟩ here") == "Keep Claude here")
    #expect(ModelChoice.opus.thinking == .object(["type": .string("adaptive")]))
}
