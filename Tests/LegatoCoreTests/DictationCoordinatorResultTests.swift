import Foundation
import Testing
@testable import LegatoCore

/// A press that leaves its text in the Live Activity's result state: no clipboard, nothing typed.
@MainActor
@Suite struct DictationCoordinatorResultTests {
    typealias Outcome = DictationCoordinator.Outcome

    static let result = StartOptions(target: .result)

    @Test func aResultRunEndsInTheResultStateAndLeavesTheClipboardAlone() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        #expect(await r.coordinator.toggle(Self.result) == .started)
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        #expect(r.clipboard.written.isEmpty)
        let end = try #require(r.activity.ends.first)
        #expect(r.activity.ends.count == 1)
        #expect(end.phase == .result && end.tail == "hello world")
        #expect(r.phaseTrail == [.starting, .listening, .finishing, .result])
        #expect(await r.history.entries.map(\.text) == ["hello world"])
    }

    @Test func theCoordinatorHandsTheResultToTheApp() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        var results: [DictationResult] = []
        r.coordinator.onResult = { results.append($0) }
        _ = await r.coordinator.toggle(Self.result)
        _ = await r.coordinator.toggle()
        let result = try #require(results.first)
        #expect(results.count == 1)
        #expect(result.text == "hello world")
        #expect(result.isActionable(now: result.at))
    }

    @Test func aResultRunWithNothingRecognizedEndsFailedWithNoResult() async throws {
        let r = CoordinatorRig(script: [.init(text: "um", isFinal: false)])
        var results: [DictationResult] = []
        r.coordinator.onResult = { results.append($0) }
        _ = await r.coordinator.toggle(Self.result)
        #expect(await r.coordinator.toggle() == .stopped(nil))
        #expect(results.isEmpty)
        #expect(r.activity.ends.map(\.phase) == [.failed])
    }

    @Test func otherTargetsKeepTheirClipboardBehaviour() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        var results: [DictationResult] = []
        r.coordinator.onResult = { results.append($0) }
        _ = await r.coordinator.toggle(StartOptions())
        _ = await r.coordinator.toggle()
        #expect(r.clipboard.written == ["hello world"])
        #expect(r.activity.ends.map(\.phase) == [.copied])
        #expect(results.isEmpty)
    }
}
