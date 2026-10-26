import Observation
import ServiceManagement

/// Launch at login through `SMAppService.mainApp`.
@MainActor @Observable
final class LoginItem {
    private(set) var isEnabled: Bool
    private(set) var lastError: String?

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}
