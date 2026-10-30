import Foundation
import LegatoCore

public enum SessionProbeError: Error, Sendable, Equatable {
    case busy, unsupportedMode, noBackends, backgroundTransitionFailed, invalidOwner
}
public enum SessionProbeMode: String, Sendable, Codable, CaseIterable { case foreground, background, backgroundAudio = "background-audio" }
public enum SessionProbeOutcome: String, Sendable, Codable { case ok, unavailable, cancelled, expired, failed, busy, backgroundTransitionFailed, restorationFailed }
public struct SessionProbeSnapshot: Sendable, Codable, Equatable {
    public var appState: String
    public var backgroundTimeRemainingS: Double?
    public var footprintMB: Int?
    public var availableMB: Int?
    public var memoryWarnings: Int?
    public init(appState: String, backgroundTimeRemainingS: Double? = nil, footprintMB: Int? = nil,
                availableMB: Int? = nil, memoryWarnings: Int? = nil) {
        self.appState = appState; self.backgroundTimeRemainingS = backgroundTimeRemainingS
        self.footprintMB = footprintMB; self.availableMB = availableMB; self.memoryWarnings = memoryWarnings
    }
}
public struct SessionProbeMeasurement: Sendable, Codable, Equatable {
    public var turn: String
    public var promptChars: Int
    public var wallMs: Int
    public var promptTokens: Int?
    public var prefilledTokens: Int?
    public var prefillMs: Int?
    public var replyEqual: Bool?
    public init(turn: String, promptChars: Int, wallMs: Int, metrics: LLMTurnMetrics? = nil, replyEqual: Bool? = nil) {
        self.turn = turn; self.promptChars = promptChars; self.wallMs = wallMs
        promptTokens = metrics?.promptTokens; prefilledTokens = metrics?.prefilledTokens
        prefillMs = metrics?.prefillSeconds.map { Int($0 * 1000) }; self.replyEqual = replyEqual
    }
}
public struct SessionProbeEvent: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case started = "session.probe.start", progress = "session.probe.progress", measurement = "session.probe", completed = "session.probe.done" }
    public let kind: Kind
    public let id: UUID
    public let mode: SessionProbeMode
    public var backend: String?
    public var phase: String?
    public var measurement: SessionProbeMeasurement?
    public var outcome: SessionProbeOutcome?
    public var snapshot: SessionProbeSnapshot
    public init(kind: Kind, id: UUID, mode: SessionProbeMode, backend: String? = nil, phase: String? = nil,
                measurement: SessionProbeMeasurement? = nil, outcome: SessionProbeOutcome? = nil, snapshot: SessionProbeSnapshot) {
        self.kind = kind; self.id = id; self.mode = mode; self.backend = backend; self.phase = phase
        self.measurement = measurement; self.outcome = outcome; self.snapshot = snapshot
    }
}
public struct SessionProbeBackend: Sendable {
    public let id: String
    public let backend: any LLMBackend
    public let measuresKickstart: Bool
    public let release: @Sendable () async -> Void
    public init(id: String, backend: any LLMBackend, measuresKickstart: Bool, release: @escaping @Sendable () async -> Void = {}) {
        self.id = id; self.backend = backend; self.measuresKickstart = measuresKickstart; self.release = release
    }
}

@MainActor public final class SessionProbeCoordinator {
    public struct Hooks {
        public var supportedModes: Set<SessionProbeMode>
        public var isBusy: @MainActor () -> Bool
        public var reserve: @MainActor (UUID) async throws -> Void
        public var begin: @MainActor (UUID, SessionProbeMode, @escaping @MainActor () -> Void) async throws -> Void
        public var releaseAppModels: @MainActor (UUID) async throws -> Void
        public var prepare: @MainActor (UUID) async throws -> [SessionProbeBackend]
        public var armAudio: @MainActor (UUID) async throws -> Bool
        public var waitForBackground: @MainActor () async throws -> Bool
        public var cleanup: @MainActor (UUID) async -> Void
        public var restoreAppModels: @MainActor (UUID) async throws -> Void
        public var releaseReservations: @MainActor (UUID) async -> Void
        public var snapshot: @MainActor () -> SessionProbeSnapshot
        public var emit: @MainActor (SessionProbeEvent) -> Void
        public init(supportedModes: Set<SessionProbeMode> = [.foreground], isBusy: @escaping @MainActor () -> Bool = { false },
                    reserve: @escaping @MainActor (UUID) async throws -> Void = { _ in },
                    begin: @escaping @MainActor (UUID, SessionProbeMode, @escaping @MainActor () -> Void) async throws -> Void = { _, _, _ in },
                    releaseAppModels: @escaping @MainActor (UUID) async throws -> Void = { _ in },
                    prepare: @escaping @MainActor (UUID) async throws -> [SessionProbeBackend],
                    armAudio: @escaping @MainActor (UUID) async throws -> Bool = { _ in false },
                    waitForBackground: @escaping @MainActor () async throws -> Bool = { false },
                    cleanup: @escaping @MainActor (UUID) async -> Void = { _ in },
                    restoreAppModels: @escaping @MainActor (UUID) async throws -> Void = { _ in },
                    releaseReservations: @escaping @MainActor (UUID) async -> Void = { _ in },
                    snapshot: @escaping @MainActor () -> SessionProbeSnapshot = { .init(appState: "active") },
                    emit: @escaping @MainActor (SessionProbeEvent) -> Void) {
            self.supportedModes = supportedModes; self.isBusy = isBusy; self.reserve = reserve; self.begin = begin
            self.releaseAppModels = releaseAppModels; self.prepare = prepare; self.armAudio = armAudio
            self.waitForBackground = waitForBackground; self.cleanup = cleanup; self.restoreAppModels = restoreAppModels
            self.releaseReservations = releaseReservations; self.snapshot = snapshot; self.emit = emit
        }
    }
    private let measurements: SessionProbeMeasurements
    private var owner: UUID?
    private var task: Task<Void, Never>?
    private var cancellationOutcome = SessionProbeOutcome.cancelled
    public init(measurements: SessionProbeMeasurements = .init()) { self.measurements = measurements }
    public var isRunning: Bool { owner != nil }
    public func owns(_ id: UUID?) -> Bool { guard let id else { return false }; return owner == id }

    /// Reserve synchronously, before the task can suspend or another ingress can request a run.
    public func start(mode: SessionProbeMode, hooks: Hooks) throws -> UUID? {
        guard hooks.supportedModes.contains(mode) else { throw SessionProbeError.unsupportedMode }
        guard owner == nil, !hooks.isBusy() else { return nil }
        let id = UUID()
        owner = id; cancellationOutcome = .cancelled
        task = Task { @MainActor in await run(id: id, mode: mode, hooks: hooks) }
        return id
    }
    public func cancel(id: UUID, expired: Bool = false) {
        guard owner == id else { return }
        cancellationOutcome = expired ? .expired : .cancelled
        task?.cancel()
    }
    public func waitUntilFinished() async { let current = task; await current?.value }

    private func run(id: UUID, mode: SessionProbeMode, hooks: Hooks) async {
        func event(_ kind: SessionProbeEvent.Kind, phase: String? = nil, backend: String? = nil,
                   measurement: SessionProbeMeasurement? = nil, outcome: SessionProbeOutcome? = nil) {
            hooks.emit(.init(kind: kind, id: id, mode: mode, backend: backend, phase: phase,
                             measurement: measurement, outcome: outcome, snapshot: hooks.snapshot()))
        }
        event(.started)
        var backends: [SessionProbeBackend] = []
        var releasedAppModels = false
        var leftBackground = false
        var outcome = SessionProbeOutcome.ok
        do {
            try Task.checkCancellation()
            try await hooks.reserve(id)
            try Task.checkCancellation()
            try await hooks.begin(id, mode) { [weak self] in self?.cancel(id: id, expired: true) }
            event(.progress, phase: "releasing")
            releasedAppModels = true
            try await hooks.releaseAppModels(id)
            try Task.checkCancellation()
            event(.progress, phase: "preparing")
            backends = try await hooks.prepare(id)
            try Task.checkCancellation()
            guard !backends.isEmpty else { throw SessionProbeError.noBackends }
            if mode == .backgroundAudio {
                guard try await hooks.armAudio(id) else { throw SessionProbeError.backgroundTransitionFailed }
            }
            if mode != .foreground {
                event(.progress, phase: "waiting-for-background")
                guard try await hooks.waitForBackground(), hooks.snapshot().appState == "background" else {
                    throw SessionProbeError.backgroundTransitionFailed
                }
            }
            for descriptor in backends {
                try Task.checkCancellation()
                event(.progress, phase: "measuring", backend: descriptor.id)
                do {
                    try await measurements.run(descriptor) { measurement in
                        event(.measurement, backend: descriptor.id, measurement: measurement)
                        if mode != .foreground, hooks.snapshot().appState != "background" {
                            leftBackground = true
                            self.task?.cancel()
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { outcome = .failed; event(.progress, phase: "backend-failed", backend: descriptor.id) }
            }
            try Task.checkCancellation()
        } catch is CancellationError { outcome = leftBackground ? .backgroundTransitionFailed : cancellationOutcome }
        catch SessionProbeError.busy { outcome = .busy }
        catch SessionProbeError.noBackends { outcome = .unavailable }
        catch SessionProbeError.backgroundTransitionFailed { outcome = .backgroundTransitionFailed }
        catch { outcome = .failed }

        let prepared = backends, shouldRestore = releasedAppModels
        let restored = await Task { @MainActor in
            for descriptor in prepared { await descriptor.release() }
            await hooks.cleanup(id)
            var restored = true
            if shouldRestore {
                event(.progress, phase: "restoring")
                do { try await hooks.restoreAppModels(id) } catch { restored = false }
            }
            await hooks.releaseReservations(id)
            return restored
        }.value
        if !restored { outcome = .restorationFailed }
        else if Task.isCancelled { outcome = leftBackground ? .backgroundTransitionFailed : cancellationOutcome }
        owner = nil; task = nil
        event(.completed, outcome: outcome)
    }
}
