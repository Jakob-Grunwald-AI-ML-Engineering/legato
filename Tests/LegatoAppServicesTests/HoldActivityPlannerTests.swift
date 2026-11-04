import Foundation
import Testing
@testable import LegatoAppServices

@Suite struct HoldActivityPlannerTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func run(_ p: inout HoldActivityPlanner, armed: Bool = true, listening: Bool = false,
                     tail: String = "", at: TimeInterval = 0, succeeds: Bool = true) -> HoldActivityPlanner.Step? {
        let now = t0.addingTimeInterval(at)
        let step = p.plan(armed: armed, listening: listening, tail: tail, now: now)
        if let step { p.performed(step, succeeded: succeeds, now: now) }
        return step
    }

    @Test func requestsOnArmThenStaysQuiet() {
        var p = HoldActivityPlanner()
        #expect(run(&p, armed: false) == nil)
        #expect(run(&p) == .request(.held, tail: ""))
        #expect(run(&p) == nil)
    }

    @Test func takeIsAContentUpdateAndBackToHeld() {
        var p = HoldActivityPlanner()
        _ = run(&p)
        #expect(run(&p, listening: true) == .update(.listening, tail: ""))
        #expect(run(&p, listening: true) == nil)
        #expect(run(&p, listening: false, tail: "left over") == .update(.held, tail: ""))
    }

    @Test func tailUpdatesAreThrottled() {
        var p = HoldActivityPlanner()
        _ = run(&p)
        _ = run(&p, listening: true)
        #expect(run(&p, listening: true, tail: "hello", at: 0.2) == nil)
        #expect(run(&p, listening: true, tail: "hello world", at: 1.5) == .update(.listening, tail: "hello world"))
        #expect(run(&p, listening: true, tail: "hello world", at: 3) == nil)
    }

    @Test func releaseEndsOnceAndRearmRequestsAgain() {
        var p = HoldActivityPlanner()
        _ = run(&p)
        #expect(run(&p, armed: false) == .end)
        #expect(run(&p, armed: false) == nil)
        #expect(run(&p) == .request(.held, tail: ""))
    }

    @Test func refusedRequestIsNotRetriedWithinTheHold() {
        var p = HoldActivityPlanner()
        #expect(run(&p, succeeds: false) == .request(.held, tail: ""))
        #expect(run(&p) == nil)
        #expect(run(&p, listening: true) == nil)
        #expect(run(&p, armed: false) == nil)
        #expect(run(&p) == .request(.held, tail: ""))
    }
}
