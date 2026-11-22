import Foundation
import LegatoAppServices
import LegatoCore
import Observation
import os

/// The Live Activity of the held microphone (#229). While the app keeps the mic open in the background iOS
/// would show its bare recording pill; a running activity of ours takes its place in the Dynamic Island.
///
/// One activity per hold: requested when the mic is armed (`ActivityKitClient.request` only works in the
/// foreground, and the arm URL opens the app), updated between `held` and `listening` as takes come and go,
/// dismissed at once when the hold is released. ActivityKit refusing never blocks arming or a take.
@MainActor
final class HoldActivityPresenter {
    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "hold-activity")

    private let microphone: MicrophoneHost
    private let keyboard: KeyboardSession
    private let client = ActivityKitClient()
    private var planner = HoldActivityPlanner()
    private var queue: Task<Void, Never>?
    private var arming = false
    private var armCancelled = false
    private var stopping = false

    private var activeHoldID: String?
    var onDismissal: (@MainActor (String) async -> Void)?

    init(microphone: MicrophoneHost, keyboard: KeyboardSession) {
        self.microphone = microphone
        self.keyboard = keyboard
        observe()
    }

    /// Runs `arm` with the activity requested first: audio activation must not precede the request, or iOS
    /// may stop the background recording. A failed arm takes the activity down again.
    func arming(_ arm: () async -> Void) async {
        guard !arming, !stopping else { return }
        arming = true
        armCancelled = false
        defer {
            arming = false
            reconcile()
        }
        if !microphone.isArmed {
            // The previous lease may have ended before its observation was delivered.
            if let end = planner.plan(armed: false, listening: false, tail: "") { enqueue(end) }
            if let request = planner.plan(armed: true, listening: false, tail: "", recovering: true) {
                Self.log.notice("request before audio activation")
                await enqueue(request).value
            }
        }
        guard !armCancelled else { return }
        await arm()
        Self.log.notice("armed=\(self.microphone.isArmed, privacy: .public)")
    }

    func ownsHold(_ holdID: String?) -> Bool {
        holdID != nil && holdID == activeHoldID && !stopping
    }

    /// The button and a system dismissal both end the hold that owns this activity.
    func stop(holdID: String?, release: () async -> Void) async {
        guard ownsHold(holdID) else { return }
        stopping = true
        armCancelled = true
        defer {
            stopping = false
            if !arming { reconcile() }
        }
        await release()
    }

    private func observe() {
        withObservationTracking {
            _ = microphone.isArmed; _ = microphone.status; _ = keyboard.dictationTail; _ = keyboard.route; _ = microphone.microphoneRecovering
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if !self.arming { self.reconcile() }
                self.observe()
            }
        }
    }

    private func reconcile() {
        guard !stopping, let step = planner.plan(armed: microphone.isArmed, listening: keyboard.route != .idle, tail: keyboard.dictationTail,
                                      recovering: microphone.microphoneRecovering) else { return }
        enqueue(step)
    }

    /// Steps run one after another, so an end never overtakes the request before it.
    @discardableResult
    private func enqueue(_ step: HoldActivityPlanner.Step) -> Task<Void, Never> {
        // Optimistic: the next plan must see this step as done even while it is still in flight.
        planner.performed(step)
        switch step {
        case .request: activeHoldID = UUID().uuidString
        case .end: activeHoldID = nil
        case .update: break
        }
        let holdID = activeHoldID
        let previous = queue
        let task = Task { [weak self] in
            await previous?.value
            await self?.run(step, holdID: holdID)
        }
        queue = task
        return task
    }

    private func run(_ step: HoldActivityPlanner.Step, holdID: String?) async {
        switch step {
        case .request(let phase, let tail):
            guard let holdID, holdID == activeHoldID else { return }
            do {
                try await client.request(content(phase, tail), holdID: holdID) { [weak self] in
                    await self?.onDismissal?(holdID)
                }
                Self.log.notice("requested phase=\(phase.rawValue, privacy: .public)")
            } catch {
                if holdID == activeHoldID {
                    activeHoldID = nil
                    planner.performed(.end)
                }
                Self.log.error("request failed: \(String(describing: error), privacy: .public)")
            }
        case .update(let phase, let tail):
            guard let holdID, holdID == activeHoldID else { return }
            await client.update(content(phase, tail), staleDate: nil)
            Self.log.notice("update phase=\(phase.rawValue, privacy: .public)")
        case .end:
            await client.dismiss()
            Self.log.notice("ended")
        }
    }

    private func content(_ phase: DictationPhase, _ tail: String) -> DictationActivityContent {
        DictationActivityContent(startedAt: Date(), tail: LiveTranscript.tail(of: tail), phase: phase)
    }
}
