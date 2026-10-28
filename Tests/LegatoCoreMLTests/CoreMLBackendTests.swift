import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoCoreML

private final class DriverCalls: Sendable {
    let value = Mutex((loads: 0, generations: 0, prompts: [String]()))
}
private struct ImmediateDriver: CoreMLDriving {
    let calls: DriverCalls
    let contextLength = 2048
    func tokens(instructions: String, examples: [LLMExample], prompt: String) async throws -> [Int] {
        calls.value.withLock { $0.prompts.append(CoreMLPrompt.render(instructions: instructions, examples: examples, prompt: prompt)) }
        return [1, 2, 3]
    }
    func generate(tokens: [Int], outputLimit: Int) async throws -> CoreMLGeneration {
        calls.value.withLock { $0.generations += 1 }
        return .init(text: "Clean text", stopReason: "eos_token")
    }
}
struct CoreMLBackendTests {
    private let spec = CoreMLModels.specs[0]
    @Test func unpreparedResponseNeverLoadsOrGenerates() async {
        let calls = DriverCalls()
        let backend = CoreMLBackend(spec: spec, folder: URL(filePath: "/absent")) { _ in
            calls.value.withLock { $0.loads += 1 }
            return ImmediateDriver(calls: calls)
        }
        #expect(await backend.availability.isAvailable == false)
        await #expect(throws: (any Error).self) { try await backend.respond(instructions: "Clean", prompt: "Hello") }
        #expect(calls.value.withLock { $0.loads } == 0)
    }
    @Test func preparationLoadsOnceWithoutGeneratingAndReusesAcrossResponses() async throws {
        let calls = DriverCalls()
        let backend = CoreMLBackend(spec: spec, folder: URL(filePath: "/fixture")) { _ in
            calls.value.withLock { $0.loads += 1 }; return ImmediateDriver(calls: calls)
        }
        try await backend.prepare()
        try await backend.prepare()
        #expect(await backend.isPrepared())
        #expect(calls.value.withLock { $0.loads } == 1)
        #expect(calls.value.withLock { $0.generations } == 0)
        #expect(try await backend.respond(instructions: "Clean", examples: [.init(user: "um", assistant: "")], prompt: "A") == "Clean text")
        #expect(try await backend.respond(instructions: "Clean", prompt: "B") == "Clean text")
        #expect(calls.value.withLock { $0.generations } == 2)
        #expect(calls.value.withLock { $0.loads } == 1)
        await backend.unload()
        #expect(await backend.isPrepared() == false)
        try await backend.prepare()
        #expect(calls.value.withLock { $0.loads } == 2)
    }
    @Test func storeSharesWarmupAndResolutionUntilRelease() async {
        let store = CoreMLModelStore()
        let root = URL(filePath: "/fixture")
        let first = await store.backend(for: spec, root: root)
        let second = await store.backend(for: spec, root: root)
        #expect(first === second)
        await store.release(folder: spec.folder(root: root))
        let third = await store.backend(for: spec, root: root)
        #expect(third !== first)
    }
}
