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

    private let composer: ComposerSession
    private let client = ActivityKitClient()
    private var planner = HoldActivityPlanner()
    private var queue: Task<Void, Never>?
    private var arming = false

    init(composer: ComposerSession) {
        self.composer = composer
        observe()
    }

    /// Runs `arm` with the activity requested first: audio activation must not precede the request, or iOS
    /// may stop the background recording. A failed arm takes the activity down again.
    func arming(_ arm: () async -> Void) async {
        arming = true
        defer { arming = false }
        if !composer.isArmed, let step = planner.plan(armed: true, listening: false, tail: "") {
            Self.log.notice("request before audio activation")
            await enqueue(step).value
        }
        await arm()
        Self.log.notice("armed=\(self.composer.isArmed, privacy: .public)")
        reconcile()
    }

    private func observe() {
        withObservationTracking {
            _ = composer.isArmed; _ = composer.status; _ = composer.tail
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if !self.arming { self.reconcile() }
                self.observe()
            }
        }
    }

    private func reconcile() {
        guard let step = planner.plan(armed: composer.isArmed, listening: composer.isListening, tail: composer.tail) else { return }
        enqueue(step)
    }

    /// Steps run one after another, so an end never overtakes the request before it.
    @discardableResult
    private func enqueue(_ step: HoldActivityPlanner.Step) -> Task<Void, Never> {
        // Optimistic: the next plan must see this step as done even while it is still in flight.
        planner.performed(step)
        let previous = queue
        let task = Task { [weak self] in
            await previous?.value
            await self?.run(step)
        }
        queue = task
        return task
    }

    private func run(_ step: HoldActivityPlanner.Step) async {
        switch step {
        case .request(let phase, let tail):
            do {
                try await client.request(content(phase, tail))
                Self.log.notice("requested phase=\(phase.rawValue, privacy: .public)")
            } catch {
                planner.performed(.end)
                Self.log.error("request failed: \(String(describing: error), privacy: .public)")
            }
        case .update(let phase, let tail):
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
