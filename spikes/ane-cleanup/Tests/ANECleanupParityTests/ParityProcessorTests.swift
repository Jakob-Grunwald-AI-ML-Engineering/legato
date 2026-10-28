import Foundation
import Synchronization
import Testing
import LegatoCore
import LegatoAppServices
@testable import ANECleanupCore

@MainActor struct ParityProcessorTests {
    private func defaults() throws -> (String, UserDefaults) {
        let name = "legato-parity-processor-\(UUID())"
        return (name, try #require(UserDefaults(suiteName: name)))
    }
    @Test func realCleanupStageChangesTextAndReportsActualInvocation() async throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        ParityBootstrap.apply(defaults: defaults)
        let runtime = FakeRuntime(); let owner = ParityModelOwner(runtime: runtime)
        try await owner.prepare(inBackground: false)
        let events = Mutex<[ParityCleanupEvent]>([])
        let processor = ParityCleanupProcessor(owner: owner, settings: CleanupSettingsStore(defaults: defaults), event: { item in events.withLock { $0.append(item) } })
        #expect(try await processor.process("hello world", locale: Locale(identifier: "en-US")) == "Hello world.")
        #expect(events.withLock { $0.last?.status } == "completed")
        #expect(events.withLock { $0.last?.invocations } == 1)
    }
    @Test func rejectedOrEmptyReplyKeepsRawAndNeverClaimsANESuccess() async throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        ParityBootstrap.apply(defaults: defaults)
        let runtime = FakeRuntime(); let owner = ParityModelOwner(runtime: runtime)
        try await owner.prepare(inBackground: false)
        let events = Mutex<[ParityCleanupEvent]>([])
        let processor = ParityCleanupProcessor(owner: owner, settings: CleanupSettingsStore(defaults: defaults), event: { item in events.withLock { $0.append(item) } })
        await runtime.setReply("A completely unrelated answer adding many new invented details and a different destination.")
        let rejected = await processor.run("hello world", locale: Locale(identifier: "en-US"), style: .verbatim, timeout: .seconds(1))
        #expect(rejected.text == "hello world")
        #expect(rejected.guardRejected)
        #expect(events.withLock { $0.last?.status } == "guardRejected")
        await runtime.setReply("")
        #expect(try await processor.process("hello world", locale: Locale(identifier: "en-US")) == "hello world")
        #expect(events.withLock { $0.last?.failedInvocations } == 1)
        #expect(events.withLock { $0.last?.status } == "rawOrUnavailable")
    }
    @Test func liveAndRefineUseCurrentSettingsAndSameBackend() async throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        ParityBootstrap.apply(defaults: defaults)
        let settings = CleanupSettingsStore(defaults: defaults)
        settings.delivery = .live; settings.timeoutSeconds = 7
        let runtime = FakeRuntime(); let owner = ParityModelOwner(runtime: runtime)
        try await owner.prepare(inBackground: false)
        let events = Mutex<[ParityCleanupEvent]>([])
        let processor = ParityCleanupProcessor(owner: owner, settings: settings, event: { item in events.withLock { $0.append(item) } })
        #expect(processor.cleansSegmentsLive)
        #expect(processor.liveStopTimeLimit == .seconds(7))
        let live = try await processor.cleanLivePass("hello world", context: "A previous sentence.", locale: Locale(identifier: "en-US"), atStop: false)
        #expect(live.text == "Hello world.")
        #expect(await runtime.seenPrompt.contains("<before>\nA previous sentence."))
        #expect(await runtime.seenExamples.count == 11)
        _ = await processor.run("hello world", locale: Locale(identifier: "en-US"), style: .message, timeout: .seconds(14), refine: true)
        #expect(await runtime.seenInstructions.contains("drop filler words"))
        #expect(events.withLock { $0.last?.refine } == true)
        settings.enabled = false
        #expect(!processor.cleansSegmentsLive)
        #expect(try await processor.process("untouched", locale: Locale(identifier: "en-US")) == "untouched")
    }
    @Test func visibleTimeoutReturnsWhileWorkerSettlesAndPreventsConcurrentReuse() async throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        ParityBootstrap.apply(defaults: defaults)
        let runtime = FakeRuntime(); let owner = ParityModelOwner(runtime: runtime)
        try await owner.prepare(inBackground: false)
        let gate = Suspension(); await runtime.setResponseGate(gate)
        let events = Mutex<[ParityCleanupEvent]>([])
        let processor = ParityCleanupProcessor(owner: owner, settings: CleanupSettingsStore(defaults: defaults), event: { item in events.withLock { $0.append(item) } })
        let result = await processor.run("hello world", locale: Locale(identifier: "en-US"), style: .verbatim, timeout: .milliseconds(30))
        #expect(result.text == "hello world")
        #expect(result.timedOut)
        #expect(await runtime.active)
        if await runtime.active {
            do { _ = try await owner.respond(instructions: "", prompt: "second"); Issue.record("worker reused while active") }
            catch {}
        }
        #expect(events.withLock { $0.last?.status } == "timedOut")
        await gate.release()
    }
}
