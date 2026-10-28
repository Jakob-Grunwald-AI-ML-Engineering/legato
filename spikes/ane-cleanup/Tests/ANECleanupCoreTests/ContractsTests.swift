import Foundation
import Synchronization


func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}
func expectThrows(_ message: String, _ body: () throws -> Void) {
    do { try body(); fatalError("FAIL: \(message)") } catch {}
}
@main struct ContractsTests {
    static func main() async throws {
        try await reviewSafetyChecks()
        let firstCancellation = Date(timeIntervalSince1970: 100)
        let overdueDeadline = Date(timeIntervalSince1970: 200)
        let firstRequest = CancellationTimestamp.retain(first: nil, requested: firstCancellation)
        expect(firstRequest == firstCancellation, "first cancellation request establishes the timestamp")
        expect(CancellationTimestamp.retain(first: firstRequest, requested: overdueDeadline) == firstCancellation, "resumed deadline or manual cancel must not overwrite earlier OS expiry")
        expect(CancellationTimestamp.retain(first: nil, requested: overdueDeadline) == overdueDeadline, "per-run reset allows a new first cancellation timestamp")
        expectThrows("context budget must reject overflow without truncating real examples") {
            try ContextBudget.validate(input: 1800, outputCap: 300, context: 2048)
        }
        try ContextBudget.validate(input: 800, outputCap: 1024, context: 2048, exactBucket: 800)
        expectThrows("exact bucket must reject mismatching total rendered tokens") {
            try ContextBudget.validate(input: 801, outputCap: 128, context: 2048, exactBucket: 800)
        }
        expectThrows("negative input cannot be a successful measurement") {
            try ContextBudget.validate(input: -1, outputCap: 128, context: 2048)
        }
        expectThrows("upstream shifts two tokens before context limit; reserve that margin") {
            try ContextBudget.validate(input: 1024, outputCap: 1024, context: 2048)
        }
        try ContextBudget.validate(input: 1022, outputCap: 1024, context: 2048)
        expect(VoiceOutcome.classify(cancelled: true, timedOut: false, guardRejected: false, backendSucceeded: true, capped: false) == "cancelled", "cancelled voice cleanup cannot count as successful model inference")
        expect(VoiceOutcome.classify(cancelled: false, timedOut: true, guardRejected: false, backendSucceeded: false, capped: false) == "timedOut", "raw delivery after timeout remains a failed model cell")
        expect(VoiceOutcome.classify(cancelled: false, timedOut: false, guardRejected: true, backendSucceeded: true, capped: false) == "guardRejected", "guard fallback remains visible in voice rows")
        expect(VoiceOutcome.classify(cancelled: false, timedOut: false, guardRejected: false, backendSucceeded: false, capped: false) == "rawOrUnavailable", "delivered raw text is not proof the requested backend ran")
        expect(VoiceOutcome.classify(cancelled: false, timedOut: false, guardRejected: false, backendSucceeded: false, capped: true) == "capped", "capped voice output cannot count as complete cleanup")
        expect(FixtureDeadline.seconds(appState: "active", modelCold: true) == 300, "foreground cold model preparation must not be cancelled at the old 60-second deadline")
        expect(FixtureDeadline.seconds(appState: "active", modelCold: false) == 60, "warm foreground inference retains its 60-second limit")
        for state in ["background", "inactive", "unknown"] {
            expect(FixtureDeadline.seconds(appState: state, modelCold: true) == 60, "only actual active foreground grants the longer cold-load deadline")
        }
        let synthetic = try SyntheticInput.userText(totalTokens: 300) { 10 + $0.split(separator: " ").count }
        expect(synthetic.split(separator: " ").count == 290, "synthetic total includes fixed rendered overhead")
        expectThrows("synthetic overhead alone can make a target infeasible") {
            _ = try SyntheticInput.userText(totalTokens: 9) { 10 + $0.split(separator: " ").count }
        }
        let turns = [ChatTurn("system", "keep all sentences"), ChatTurn("user", "example input"),
                     ChatTurn("assistant", "example answer"), ChatTurn("user", "actual text")]
        let qwen = PromptRenderer.render(turns, family: .qwen3)
        expect(qwen == "<|im_start|>system\nkeep all sentences<|im_end|>\n<|im_start|>user\nexample input<|im_end|>\n<|im_start|>assistant\nexample answer<|im_end|>\n<|im_start|>user\nactual text<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n", "Qwen real roles/examples and thinking-off suffix must be preserved")
        let gemma = PromptRenderer.render(turns, family: .gemma3)
        expect(gemma == "<bos><start_of_turn>user\nkeep all sentences\n\nexample input<end_of_turn>\n<start_of_turn>model\nexample answer<end_of_turn>\n<start_of_turn>user\nactual text<end_of_turn>\n<start_of_turn>model\n", "Gemma folds system into first user, maps assistant to model and preserves examples")
        let trimmedGemma = PromptRenderer.render([ChatTurn("user", " hello \n")], family: .gemma3)
        expect(trimmedGemma == "<bos><start_of_turn>user\nhello<end_of_turn>\n<start_of_turn>model\n", "Gemma canonical template trims message whitespace, including synthetic fill")
        expect(StartClassification.classify(entryState: "background", recordingState: "active", foregroundHop: true, armedForeground: false) == "foregroundHop", "hop cannot count as background start")
        expect(StartClassification.classify(entryState: "background", recordingState: "background", foregroundHop: false, armedForeground: true) == "foregroundArmedBackground", "keyboard arming must be distinct")
        expect(StartClassification.classify(entryState: "background", recordingState: "background", foregroundHop: false, armedForeground: false) == "backgroundStart", "genuine background trigger classified separately")
        let lease = RunLease()
        try lease.begin()
        lease.cancel()
        expectThrows("cancel flag must stop next prediction") { try lease.check() }
        expectThrows("cancel request does not release a running prediction") { try lease.begin() }
        lease.settle()
        try lease.begin()
        try lease.check()
        lease.settle()
        // The token-boundary check uses the same synchronized flag in prefill and decode.
        for phase in ["prefill", "decode"] {
            let active = RunLease()
            try active.begin()
            let entered = Mutex(false)
            let worker = Task.detached {
                entered.withLock { $0 = true }
                try await Task.sleep(for: .milliseconds(20)) // an in-flight prediction settles first
                try active.check() // next prediction boundary
            }
            while !entered.withLock({ $0 }) { await Task.yield() }
            active.cancel()
            expectThrows("\(phase): new run must wait for worker settlement") { try active.begin() }
            do { try await worker.value; fatalError("FAIL: \(phase) ignored cancellation") } catch {}
            active.settle()
            try active.begin()
            active.settle()
        }
        print("PASS: context, exact total tokens, chat roles, thinking off, trigger classification, prefill/decode cancellation and settlement")
    }
}

// Ownership checks are invoked by main above, independently of platform frameworks.
func reviewSafetyChecks() async throws {
    let safety = WorkerOwnership()
    try safety.beginRun(id: "first", opaqueCancellation: true, state: "background")
    expect(!safety.wasInvoked(runID: "first"), "empty ASR cannot borrow a previous inference invocation")
    try safety.beginWorker(runID: "first")
    expect(safety.wasInvoked(runID: "first"), "metrics belong only to the invoked run")
    expect(!safety.wasInvoked(runID: "other"), "another run cannot claim inference metrics")
    safety.observe(state: "active")
    safety.observe(state: "background")
    expect(!safety.backgroundEligible(settlementState: "background"), "foreground interruption invalidates background-only completion even after returning to background")
    safety.cancel()
    expect(!safety.canContinueBatch, "deadline cancellation stops remaining repeats")
    expectThrows("model reset cannot overlap a worker") { try safety.requireReusable() }
    let waiterReturned = Mutex(false)
    let waiter = Task.detached { await safety.waitUntilSettled(); waiterReturned.withLock { $0 = true } }
    try await Task.sleep(for: .milliseconds(30))
    expect(!waiterReturned.withLock { $0 }, "pipeline returning cannot release an unfinished backend worker")
    safety.finishWorker(cancelled: true)
    await waiter.value
    expectThrows("opaque cancelled baseline stays quarantined after its public API returns") { try safety.requireReusable() }
    let joinable = WorkerOwnership()
    try joinable.beginRun(id: "joined", opaqueCancellation: false, state: "background")
    try joinable.beginWorker(runID: "joined")
    joinable.cancel(); joinable.finishWorker(cancelled: true)
    try joinable.requireReusable()
    try joinable.beginRun(id: "empty", opaqueCancellation: false, state: "background")
    expect(!joinable.wasInvoked(runID: "empty"), "new empty voice run cannot retain previous metrics")
    expect(joinable.backgroundEligible(settlementState: "background"), "uninterrupted background run retains eligibility")
    expect(!joinable.backgroundEligible(settlementState: "active"), "foreground settlement cannot prove background completion")
}
