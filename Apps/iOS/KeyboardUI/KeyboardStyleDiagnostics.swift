import Foundation
import LegatoCore
import LegatoKeyboardCore

/// Internal app and extension share the same rotating metadata file as the operator's diagnostics export.
enum KeyboardStyleDiagnostics {
    static func makeLog(root: URL) -> StyleDiagnosticLog? {
        #if DEBUG || LEGATO_INTERNAL
        return StyleDiagnosticLog(directory: root.appending(path: "Library/Caches", directoryHint: .isDirectory),
                                  platform: .iOS, settingsRoot: root)
        #else
        return nil
        #endif
    }
}

/// One direct emoji edit awaiting exact confirmation in the same field. An intervening operation retires it.
struct StyleKeyConfirmation {
    let field: KeyboardPresence.StyleField
    let operation: ShadowOp
    let expected: FieldQueue.Report
    let event: StyleDiagnosticEvent
    private(set) var sent = false

    init(field: KeyboardPresence.StyleField, operation: ShadowOp, expected: FieldQueue.Report, event: StyleDiagnosticEvent) {
        self.field = field
        self.operation = operation
        self.expected = expected
        self.event = event
    }

    mutating func dispatched(_ op: ShadowOp, lane: FieldQueue.Lane) -> Bool {
        guard !sent, lane == .user, op == operation else { return false }
        sent = true
        return true
    }
}
