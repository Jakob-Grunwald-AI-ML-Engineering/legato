import AppKit
import Foundation
import LegatoAppServices
import LegatoMac

/// Watches for another app's call while the setting is on, and offers or starts a meeting for it.
///
/// - **Polling.** Once a second the audio process list is read (`MicInUseMonitor`) and `CallDetectionPolicy` decides
///   from it; nothing runs while the mode is Off. The policy keeps Legato's own processes out, waits out a blip, and
///   begins a call once.
/// - **Prompt** shows `CallPromptController` with Record; **Auto-record** starts the meeting by itself. Either way
///   nothing starts while a dictation, the composer or a meeting is in use.
/// - **Ending.** When the call is over a meeting that started by itself stops (`startedAutomatically`); one the user
///   started, from the prompt too, is never stopped from here.
@MainActor
final class CallDetectionController {
    private static let bundlePrefix = "de.gruenwald.legato"
    private let settings = MeetingSettings(defaults: .standard)
    private let meetings: MeetingController
    private let busy: () -> Bool
    private let startMeeting: (_ automatically: Bool) -> Void
    private let prompt = CallPromptController()
    private let monitor = MicInUseMonitor()
    private var policy = CallDetectionPolicy(ownPID: ProcessInfo.processInfo.processIdentifier, ownBundlePrefix: bundlePrefix)
    private var pollTask: Task<Void, Never>?
    private var observer: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - busy: a dictation or the composer is in use.
    ///   - startMeeting: starts a meeting the way the menu does (microphone permission and all); the flag says it
    ///     starts by itself.
    init(meetings: MeetingController, busy: @escaping () -> Bool, startMeeting: @escaping (_ automatically: Bool) -> Void) {
        self.meetings = meetings
        self.busy = busy
        self.startMeeting = startMeeting
        prompt.onRecord = { [weak self] in self?.startMeeting(false) }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconfigure() }
        }
        reconfigure()
    }

    /// Runs the monitor while the mode is not Off, and only then.
    private func reconfigure() {
        if settings.callDetection == .off {
            pollTask?.cancel()
            pollTask = nil
            prompt.hide()
            policy = CallDetectionPolicy(ownPID: ProcessInfo.processInfo.processIdentifier, ownBundlePrefix: Self.bundlePrefix)
        } else if pollTask == nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    let monitor = self?.monitor
                    let processes = await Task.detached { try? monitor?.activeProcesses() }.value
                    guard !Task.isCancelled, let self else { return }
                    if let processes { tick(processes) }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func tick(_ processes: [AutoMuteProcess]) {
        let inUse = busy()
        if inUse || meetings.isRecording { prompt.hide() }
        let event = policy.update(
            processes: processes, dictationBusy: inUse, meetingActive: meetings.isRecording, at: ProcessInfo.processInfo.systemUptime)
        switch event {
        case .began(let call):
            switch settings.callDetection {
            case .prompt: prompt.show(appName: Self.appName(of: call))
            case .autoRecord: startMeeting(true)
            case .off: break
            }
        case .ended:
            prompt.hide()
            if event?.stopsMeeting(startedAutomatically: meetings.startedAutomatically) == true, meetings.phase == .recording { meetings.stop() }
        case nil: break
        }
    }

    /// The name of the app on the call: the process's own, or the app it is a helper of (a browser's audio process).
    private static func appName(of call: CallDetectionPolicy.Call) -> String {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let own = apps.first { $0.processIdentifier == call.pid }
        let parent = apps.filter { app in app.bundleIdentifier.map { call.bundleID == $0 || call.bundleID.hasPrefix($0 + ".") } ?? false }
            .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
        return (own ?? parent)?.localizedName ?? "Another app"
    }
}
