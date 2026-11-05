import Testing
import LegatoCore
@testable import LegatoAppServices

@Test func startupBufferPreservesOpeningAudioInOrderAndClearsBetweenTakes() throws {
    var buffer = TakeAudioBuffer(limit: 1)
    let format = AudioFormatSpec(sampleRate: 16000, channelCount: 1)
    let opening = AudioChunk(samples: [0.1, 0.2], format: format)
    let following = AudioChunk(samples: [0.3], format: format)
    try buffer.append(opening); try buffer.append(following)
    #expect(buffer.takeAll().flatMap(\.samples) == [0.1, 0.2, 0.3])
    #expect(buffer.takeAll().isEmpty)
    try buffer.append(opening); buffer.removeAll()
    #expect(buffer.takeAll().isEmpty, "Idle or abandoned audio never leaks into the next take")
}

@Test func startupBufferFailsInsteadOfEvictingTheFirstWords() throws {
    var buffer = TakeAudioBuffer(limit: 0.02)
    let first = AudioChunk(samples: Array(repeating: 0.1, count: 320), format: .init(sampleRate: 16000, channelCount: 1))
    try buffer.append(first)
    #expect(throws: TakeAudioBuffer.Failure.self) { try buffer.append(first) }
    #expect(buffer.takeAll().flatMap(\.samples) == first.samples)
}
