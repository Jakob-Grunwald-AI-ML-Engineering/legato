#if LEGATO_INTERNAL
import AVFAudio
import Foundation
import LegatoAppServices
import UIKit
import os

/// Internal platform lifetime and presentation hooks. Measurements remain in LegatoAppServices.
@MainActor enum SessionProbe {
    private static let coordinator = SessionProbeCoordinator()
    private static var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private static var sampler: Task<Void, Never>?
    private static var memoryObserver: NSObjectProtocol?
    private static var warnings = 0
    private(set) static var ignoresMemoryWarnings = false
    static var isRunning: Bool { coordinator.isRunning }
    static func owns(_ owner: UUID?) -> Bool { coordinator.owns(owner) }
    private static var currentID: UUID?

    static func cancel(expired: Bool = false, cause: String = "explicit") {
        guard let currentID else { return }
        AudioDiagnostics.log("session.probe.cancel-request", ["probeID": currentID.uuidString,
            "cause": cause, "expired": expired])
        coordinator.cancel(id: currentID, expired: expired)
    }

    static func captureSystemEvent() -> SessionProbeCoordinator.SystemEventToken { coordinator.captureSystemEvent() }

    static func cancelForSystemEvent(_ kind: SessionProbeSystemEvent, event: SessionProbeCoordinator.SystemEventToken,
                                     cause: String, isCurrent: Bool, requiresStop: Bool) {
        let accepted = coordinator.cancelForSystemEvent(event: event, kind: kind,
            isCurrent: isCurrent, requiresStop: requiresStop)
        AudioDiagnostics.log("session.probe.system-event", ["probeID": currentID?.uuidString ?? "",
            "capturedProbeID": event.owner?.uuidString ?? "",
            "kind": kind.rawValue, "cause": cause, "isCurrent": isCurrent,
            "requiresStop": requiresStop, "cancelAccepted": accepted])
    }

    static func start(commandID: String, mode: SessionProbeMode, ignoreMemoryWarnings: Bool = false) throws -> UUID? {
        guard !isRunning else { return nil }
        guard UIApplication.shared.applicationState == .active else { throw PlatformError.startInForeground }
        let app = AppController.shared
        let priorBlocking = DebugMessages.shared.blocking
        let hooks = SessionProbeCoordinator.Hooks(supportedModes: Set(SessionProbeMode.allCases),
            isBusy: { app.probeAdmissionBusy },
            reserve: { owner in
                try await app.models.reserveForProbe(owner)
                try await app.meetings.services.reserveForProbe(owner)
            }, begin: { owner, mode, expired in
                warnings = 0; ignoresMemoryWarnings = ignoreMemoryWarnings
                DebugMessages.shared.setBlocking(true)
                if mode != .foreground {
                    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "session.probe") {
                        MainActor.assumeIsolated {
                            AudioDiagnostics.log("session.probe.cancel-request", ["probeID": owner.uuidString,
                                "cause": "background-expired", "expired": true])
                            expired(); endBackgroundTask()
                        }
                    }
                    guard backgroundTask != .invalid else { throw SessionProbeError.backgroundTransitionFailed }
                }
                memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                    object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        warnings += 1
                        AudioDiagnostics.log("session.probe.memoryWarning", ["probeID": owner.uuidString, "warnings": warnings])
                        if !ignoresMemoryWarnings { cancel(cause: "memory-warning") }
                    }
                }
                sampler = Task { @MainActor in
                    while !Task.isCancelled {
                        let memory = snapshot()
                        AudioDiagnostics.log("session.probe.memory", ["probeID": owner.uuidString,
                            "footprintMB": memory.footprintMB ?? -1, "availableMB": memory.availableMB ?? -1,
                            "memoryWarnings": warnings])
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    }
                }
            }, releaseAppModels: { owner in try await app.releaseModelsForProbe(owner: owner) },
            prepare: { owner in
                try await app.models.prepareProbeBackends(owner: owner) { backend, phase in
                    AudioDiagnostics.log("session.probe.backend", ["probeID": owner.uuidString, "backend": backend, "phase": phase])
                }
            }, armAudio: { owner in try await app.armMicrophoneForProbe(owner: owner) },
            waitForBackground: {
                let deadline = ContinuousClock.now + .seconds(180)
                while UIApplication.shared.applicationState != .background {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { return false }
                    try await Task.sleep(for: .milliseconds(250))
                }
                return true
            }, cleanup: { owner in await app.endKeepAlive(probeOwner: owner) },
            restoreAppModels: { owner in try await app.restoreModelsAfterProbe(owner: owner) },
            releaseReservations: { owner in
                sampler?.cancel(); await sampler?.value; sampler = nil
                if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
                memoryObserver = nil; ignoresMemoryWarnings = false
                await app.models.releaseProbeReservation(owner)
                await app.meetings.services.releaseProbeReservation(owner)
                endBackgroundTask()
                DebugMessages.shared.setBlocking(priorBlocking)
            }, snapshot: snapshot, emit: { event in
                var payload = fields(event, commandID: commandID)
                payload["probeID"] = event.id.uuidString
                DebugBridge.emit(id: event.id.uuidString, event: event.kind.rawValue, payload)
                AudioDiagnostics.log(event.kind.rawValue, payload)
                if let phase = event.phase { DebugBridge.status("Session probe: \(phase)") }
                if let measurement = event.measurement {
                    DebugBridge.status("Session probe: \(event.backend ?? "model") \(measurement.turn): \(measurement.wallMs) ms")
                }
                if event.kind == .completed {
                    DebugBridge.status("Session probe: \(event.outcome?.rawValue ?? "failed")")
                    currentID = nil
                    app.probeDidFinish()
                }
            })
        let id = try coordinator.start(mode: mode, hooks: hooks)
        currentID = id
        return id
    }

    private static func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    private static func snapshot() -> SessionProbeSnapshot {
        let appState: String = switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return .init(appState: appState,
            backgroundTimeRemainingS: appState == "background" ? min(UIApplication.shared.backgroundTimeRemaining, 9999) : nil,
            footprintMB: result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil,
            availableMB: Int(os_proc_available_memory() / 1_048_576), memoryWarnings: warnings)
    }
    private static func fields(_ event: SessionProbeEvent, commandID: String) -> [String: Any] {
        var result = ((try? JSONEncoder().encode(event)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        result["kind"] = nil; result["id"] = nil
        result["commandID"] = commandID
        if let outcome = event.outcome { result["ok"] = outcome == .ok }
        return result
    }
    enum PlatformError: Error { case startInForeground }
}
#endif
