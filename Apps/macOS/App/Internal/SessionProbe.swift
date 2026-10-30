#if LEGATO_INTERNAL
import AppKit
import Foundation
import LegatoAppServices

/// macOS has no iOS background execution modes. Task 5 supplies the bridge and panel callbacks.
@MainActor enum SessionProbe {
    private static let coordinator = SessionProbeCoordinator()
    private static var currentID: UUID?
    static var isRunning: Bool { coordinator.isRunning }
    static func owns(_ owner: UUID?) -> Bool { coordinator.owns(owner) }
    static func cancel() { if let currentID { coordinator.cancel(id: currentID) } }

    static func start(commandID: String, mode: SessionProbeMode,
                      status: @escaping @MainActor (String?) -> Void = { _ in },
                      block: @escaping @MainActor (Bool) -> Void = { _ in },
                      isBlocked: @MainActor () -> Bool = { false },
                      emit: @escaping @MainActor (String, String, [String: Any]) -> Void) throws -> UUID? {
        let app = MacAppController.shared
        let priorBlocking = isBlocked()
        let hooks = SessionProbeCoordinator.Hooks(supportedModes: [.foreground], isBusy: { app.probeAdmissionBusy },
            reserve: { owner in
                try await app.models.reserveForProbe(owner)
                try await app.meetings.services.reserveForProbe(owner)
            }, begin: { _, _, _ in block(true) },
            releaseAppModels: { owner in try await app.releaseModelsForProbe(owner: owner) },
            prepare: { owner in try await app.models.prepareProbeBackends(owner: owner) },
            restoreAppModels: { owner in try await app.restoreModelsAfterProbe(owner: owner) },
            releaseReservations: { owner in
                await app.models.releaseProbeReservation(owner)
                await app.meetings.services.releaseProbeReservation(owner)
                block(priorBlocking)
            }, snapshot: snapshot, emit: { event in
                var fields = ((try? JSONEncoder().encode(event)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
                fields["kind"] = nil; fields["id"] = nil
                fields["commandID"] = commandID; fields["probeID"] = event.id.uuidString
                if let outcome = event.outcome { fields["ok"] = outcome == .ok }
                emit(event.id.uuidString, event.kind.rawValue, fields)
                if let phase = event.phase { status("Session probe: \(phase)") }
                if event.kind == .completed {
                    status("Session probe: \(event.outcome?.rawValue ?? "failed")")
                    currentID = nil
                    app.probeDidFinish()
                }
            })
        let id = try coordinator.start(mode: mode, hooks: hooks)
        if let id { currentID = id }
        return id
    }
    private static func snapshot() -> SessionProbeSnapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return .init(appState: NSApp.isActive ? "active" : "inactive",
                     footprintMB: result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil)
    }
}
#endif
