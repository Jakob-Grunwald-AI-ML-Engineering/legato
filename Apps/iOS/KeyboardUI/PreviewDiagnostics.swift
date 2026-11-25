import Darwin
import Foundation
import LegatoCore
import LegatoKeyboardCore
import os

enum PreviewTransitionOutcome: String, Codable {
    case completed, cancelled, simplified, reduceMotion, unchanged
}

struct PreviewTransitionDiagnostic {
    let id: UUID
    let context: PreviewDiagnostics.Context
}

/// A bounded, metadata-only trail for Magic preview failures on internal iPhone builds. App Group files
/// keep the last events even if the keyboard process stops before the app can read from the link again.
@MainActor
final class PreviewDiagnostics {
    enum Event: String, Codable {
        case controllerCreated, willAppear, willDisappear, didDisappear, controllerTornDown, memoryWarning, autoFillSwitch
        case requestIssued, requestReceived, snapshotPublished, snapshotReceived, transitionStarted, transitionMounted, transitionEnded
        case historySaved, historyWriteFailed
    }

    struct Context: Codable {
        var runID: UUID?
        var revision: Int?
        var unitID: Int?
        var operationID: UUID?
        var phase: PreviewDiagnosticRevision.Phase?
        var inputCharacters: Int?
        var resultCharacters: Int?

        init(runID: String? = nil, revision: Int? = nil, unitID: Int? = nil, operationID: UUID? = nil,
             inputCharacters: Int? = nil, resultCharacters: Int? = nil) {
            self.runID = runID.flatMap(UUID.init(uuidString:))
            self.revision = revision
            self.unitID = unitID
            self.operationID = operationID
            self.inputCharacters = inputCharacters
            self.resultCharacters = resultCharacters
        }

        init(_ preview: PreviewDiagnosticRevision) {
            runID = preview.runID
            revision = preview.revision
            unitID = preview.unitID
            operationID = preview.operationID
            phase = preview.phase
            inputCharacters = preview.inputCharacters
            resultCharacters = preview.resultCharacters
        }
    }

    struct Keyboard: Codable {
        let controller: UUID
        let appearance: Int
        let visible: Bool
    }

    enum Role: String, Codable { case app, keyboard, harness }

    static let app = PreviewDiagnostics(.app)
    #if APP_TARGET
    static let keyboard = PreviewDiagnostics(.harness)
    #else
    static let keyboard = PreviewDiagnostics(.keyboard)
    #endif

    private let role: Role

    private init(_ role: Role) { self.role = role }

    #if DEBUG || LEGATO_INTERNAL
    private struct Entry: Encodable {
        let event: Event
        let role: Role
        let atMs: Int64
        let pid: Int32
        let processInstance: UUID
        let context: Context
        let keyboard: Keyboard?
        let command: RequestCommand?
        let transitionID: UUID?
        let outcome: PreviewTransitionOutcome?
        let footprintBytes: UInt64?
        let availableBytes: Int?
    }

    private static let log = Logger(subsystem: RuntimeIdentity.current.notificationNamespace, category: "magic-preview")
    private static let pid = ProcessInfo.processInfo.processIdentifier
    private static let processInstance = UUID()
    private let encoder = JSONEncoder()
    private lazy var file: RotatingLineFile = {
        let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LinkChannel.appGroupID)?
            .appending(path: "Library/Caches", directoryHint: .isDirectory) ?? .cachesDirectory
        let base = "magic-preview-\(role.rawValue)"
        return RotatingLineFile(directory: directory, fileName: "\(base).jsonl", previousFileName: "\(base).previous.jsonl",
                                rotateBytes: 64 * 1024)
    }()

    private static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, let offset = MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint),
              Int(count) * MemoryLayout<integer_t>.size >= offset + MemoryLayout<UInt64>.size else { return nil }
        return info.phys_footprint
    }
    #endif

    func record(_ event: Event, context: Context = .init(), keyboard: Keyboard? = nil, command: RequestCommand? = nil,
                transitionID: UUID? = nil, outcome: PreviewTransitionOutcome? = nil, sampleMemory: Bool = false) {
        #if DEBUG || LEGATO_INTERNAL
        let value = Entry(event: event, role: role, atMs: Int64(Date().timeIntervalSince1970 * 1000), pid: Self.pid,
                          processInstance: Self.processInstance, context: context, keyboard: keyboard, command: command,
                          transitionID: transitionID, outcome: outcome, footprintBytes: sampleMemory ? Self.footprint() : nil,
                          availableBytes: sampleMemory ? os_proc_available_memory() : nil)
        guard var data = try? encoder.encode(value) else { return }
        Self.log.notice("\(String(decoding: data, as: UTF8.self), privacy: .public)")
        data.append(0x0A)
        // Submit the write before proceeding to the next transition step. The process can be killed before any queued work runs.
        file.append(data)
        #endif
    }
}
