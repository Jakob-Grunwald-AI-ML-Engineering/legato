import Foundation
import LegatoKeyboardCore
import Observation
import UIKit

/// The keyboard's brain, shared by the extension and the DEBUG harness in the app: shows the link's
/// state, turns the host's dictation text into edits of the document (`ProxyEditPlanner`), reports what
/// landed (`link.applied`), keeps the presence beat while visible and decides what the mic key does.
///
/// The planner and the mic-key rules live in LegatoKeyboardCore and are tested there; this type only
/// carries them out against a `TextDocument` and the App Group.
@MainActor @Observable
final class KeyboardController {
    @ObservationIgnored let document: any TextDocument
    @ObservationIgnored private let link: LinkClient
    @ObservationIgnored private let hasFullAccess: @MainActor () -> Bool

    /// Diagnostics hook (the DEBUG harness logs it). Messages carry no user text.
    @ObservationIgnored var trace: (@MainActor (String) -> Void)?
    /// Where the globe key sends its touches (the extension's `UIInputViewController`).
    @ObservationIgnored weak var inputModeTarget: UIInputViewController?
    /// The typing rules and the page the key grid shows.
    @ObservationIgnored private(set) var typing: TypingModel!

    /// The app's last published state.
    private(set) var host: HostState?
    /// Refreshed by the presence beat and before the mic key decides, so freshness checks have a clock.
    private(set) var now = Date()
    private(set) var isVisible = false
    private(set) var returnKeyType: UIReturnKeyType = .default
    private(set) var keyboardType: UIKeyboardType = .default
    private(set) var autocapitalization: AutoCapitalizationType = .none
    private(set) var enablesReturnKeyAutomatically = false
    private(set) var hasText = false
    /// The field's keyboard appearance as an interface style (`.unspecified`: follow the system).
    private(set) var appearance: UIUserInterfaceStyle = .unspecified
    /// A line above the keys: the Full Access explainer, or the "tap again to open" fallback.
    private(set) var hint: String?
    /// The three suggestion slots above the keys (the prediction engine fills them; empty for now).
    var suggestions: [String] = []
    /// Whether to show the globe key (`needsInputModeSwitchKey`); set by the extension.
    var showsGlobe = false
    /// The id of the request the mic key's Link carries (the Darwin request uses the same id).
    private(set) var openAppRequestID = UUID().uuidString

    /// Strip or full keyboard, and the chevron that switches (`KeyboardExpansion`, per keyboard session).
    private(set) var expansion = KeyboardExpansion(stripEnabled: false)
    /// The strip's height in points; the debug long press steps it through `StripHeight.candidates`.
    private(set) var stripHeight = StripHeight.standard
    /// The extension re-sizes its view when the mode or the strip height changed (`reason` is for the log).
    @ObservationIgnored var onLayoutChange: (@MainActor (_ reason: String) -> Void)?
    @ObservationIgnored private let preferences: () -> KeyboardPreferences

    @ObservationIgnored private var cursor: AppliedCursor?
    @ObservationIgnored private var isTornDown = false
    private var forcedOpenAppUntil: Date?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var reapply: Task<Void, Never>?
    @ObservationIgnored private var hintTimeout: Task<Void, Never>?

    init(
        document: any TextDocument, link: LinkClient, hasFullAccess: @escaping @MainActor () -> Bool,
        preferences: @escaping () -> KeyboardPreferences = { .load() }
    ) {
        self.document = document
        self.link = link
        self.hasFullAccess = hasFullAccess
        self.preferences = preferences
        refreshPreferences()
        cursor = link.readApplied()
        host = link.readHost()
        link.observeHost { [weak self] in self?.hostDidChange() }
        typing = TypingModel(controller: self)
    }

    var fullAccess: Bool { hasFullAccess() }

    // MARK: Strip

    var mode: KeyboardMode { expansion.mode }

    /// Re-reads the strip setting. Turning it on or off starts a session over (collapsed with it on); the
    /// strip height comes from the setting only then, so the debug long press survives the keyboard
    /// appearing again.
    func refreshPreferences() {
        let current = preferences()
        let changed = expansion.stripEnabled != current.strip
        expansion.setStripEnabled(current.strip)
        guard changed else { return }
        stripHeight = current.stripHeight
        onLayoutChange?("setting")
    }

    /// The chevron: strip to full keyboard and back.
    func toggleExpansion() {
        guard expansion.control != nil else { return }
        expansion.toggle()
        trace?("expansion mode=\(expansion.mode == .strip ? "strip" : "full")")
        onLayoutChange?("toggle")
    }

    #if DEBUG
    /// Debug: a long press on the strip's status text steps the strip height through the candidates.
    func cycleStripHeight() {
        stripHeight = StripHeight.next(after: stripHeight)
        onLayoutChange?("cycle")
    }
    #endif

    /// The dictation status the keyboard shows in place of its suggestions (the strip's text): a hint, or
    /// "Listening…" while capturing; nil when there is nothing to say.
    var statusText: String? {
        hint ?? (isCapturing && suggestions.isEmpty ? "Listening…" : nil)
    }

    // MARK: Visibility

    /// The keyboard came on screen: beat presence once a second, and catch up with a run in progress.
    func appeared() {
        guard !isTornDown else { return }
        isVisible = true
        refreshPreferences()
        refreshTraits()
        typing.appeared()
        link.writePresence(visible: true, notify: true)
        trace?("visible value=1")
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(LinkChannel.presenceInterval))
                guard !Task.isCancelled, let self else { return }
                self.beat()
            }
        }
        hostDidChange()
    }

    func disappeared() {
        isVisible = false
        typing.disappeared()
        heartbeat?.cancel()
        heartbeat = nil
        reapply?.cancel()
        link.writePresence(visible: false, notify: true)
        trace?("visible value=0")
    }

    /// The keyboard is going away for good (its view controller is being released): stop listening to the
    /// app and cancel everything that runs, so that a controller kept alive a moment longer by a view or a
    /// pending notification does nothing.
    func tearDown() {
        guard !isTornDown else { return }
        if isVisible { disappeared() }
        isTornDown = true
        link.stopObserving()
        heartbeat?.cancel()
        reapply?.cancel()
        hintTimeout?.cancel()
        typing.disappeared()
    }

    private func beat() {
        link.writePresence(visible: true, notify: false)
        reloadHost()
    }

    /// The field or its traits changed (a new field, another return key).
    func documentDidChange() {
        refreshTraits()
        typing.documentChanged()
    }

    /// Reads the field's traits; only changed values are stored, so the keys redraw only when needed.
    func refreshTraits() {
        if returnKeyType != document.returnKeyType { returnKeyType = document.returnKeyType }
        if keyboardType != document.keyboardType { keyboardType = document.keyboardType }
        let capitalization = AutoCapitalizationType(rawValue: document.autocapitalizationType.rawValue) ?? .none
        if autocapitalization != capitalization { autocapitalization = capitalization }
        if enablesReturnKeyAutomatically != document.enablesReturnKeyAutomatically {
            enablesReturnKeyAutomatically = document.enablesReturnKeyAutomatically
        }
        if hasText != document.hasText { hasText = document.hasText }
        let style: UIUserInterfaceStyle =
            switch document.keyboardAppearance {
            case .dark: .dark
            case .light: .light
            default: .unspecified
            }
        if appearance != style { appearance = style }
    }

    // MARK: Host state

    private func reloadHost() {
        now = Date()
        let latest = link.readHost()
        if latest != host { host = latest }
    }

    private func hostDidChange() {
        guard !isTornDown else { return }
        reloadHost()
        #if DEBUG
        if let host, let insertAt = host.insertAt {
            let latency = Int((Date().timeIntervalSince(insertAt) * 1000).rounded())
            WakeProbeLog.log(
                "recv", "run=\(host.runID?.prefix(8) ?? "-") seq=\(host.seq) latencyMs=\(latency) visible=\(isVisible ? 1 : 0)")
        }
        #endif
        applyHost()
    }

    /// Brings the field in line with the host's text, when `HostApplyDecision` says so: only while visible,
    /// only for a run the app marked for the keyboard, and for a run this keyboard never followed only when
    /// its final text was asked for (the Live Activity's Insert). The last state of any other run it never
    /// saw (an old dictation, seen again when the keyboard reappears) is not typed. A "running" state whose
    /// beat has gone stale belongs to an app that died: its text is not typed either.
    private func applyHost() {
        guard !isTornDown else { return }
        let decision = HostApplyDecision.decide(
            host: host, cursor: cursor, visible: isVisible, documentID: document.documentID, now: Date())
        guard case .apply = decision, let host else {
            #if DEBUG
            if case .skip(let reason) = decision, host?.insertAt != nil {
                WakeProbeLog.log("skip", "run=\(host?.runID?.prefix(8) ?? "-") reason=\(reason.rawValue)")
            }
            #endif
            return
        }
        let before = cursor
        let plan = ProxyEditPlanner.plan(
            state: host, cursor: cursor, contextBefore: document.contextBefore, documentID: document.documentID)
        perform(plan.ops)
        guard let updated = plan.cursor, updated != before else { return }
        cursor = updated
        link.writeApplied(updated)
        if !plan.ops.isEmpty || updated.finalApplied {
            trace?("apply final=\(updated.finalApplied ? 1 : 0)")
        }
        #if DEBUG
        if host.insertAt != nil, !plan.ops.isEmpty {
            WakeProbeLog.log("insert", "run=\(host.runID?.prefix(8) ?? "-") ops=\(plan.ops.count) final=\(updated.finalApplied ? 1 : 0)")
        }
        #endif
    }

    private func perform(_ ops: [ProxyOp]) {
        for op in ops {
            switch op {
            case .deleteBackward(let count): for _ in 0..<count { document.deleteBackward() }
            case .insert(let text): document.insert(text)
            }
        }
        if !ops.isEmpty { typing.hostEdited() }
    }

    // MARK: Typing

    func type(_ text: String) {
        beforeUserEdit()
        document.insert(text)
        afterUserEdit()
    }

    func deleteBackward() {
        beforeUserEdit()
        document.deleteBackward()
        afterUserEdit()
    }

    /// The user types into a run's text: the tentative text comes out first so the key lands after the
    /// committed text; `applyHost` puts it back after the key.
    private func beforeUserEdit() {
        guard let current = cursor, let documentID = document.documentID, current.documentID == documentID,
              let host, host.runID == current.runID, host.phase != .idle
        else { return }
        let plan = ProxyEditPlanner.prepareForTyping(cursor: current, contextBefore: document.contextBefore)
        perform(plan.ops)
        if let updated = plan.cursor, updated != current {
            cursor = updated
            link.writeApplied(updated)
        }
    }

    /// The document's context settles a moment after an edit; planning against it right away would
    /// misjudge the separator. The next host update would do too, but it can be a while off.
    private func afterUserEdit() {
        guard cursor != nil else { return }
        reapply?.cancel()
        reapply = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.applyHost()
        }
    }

    // MARK: Mic key

    /// Whether the app is capturing right now (a fresh beat and a run starting or listening).
    var isCapturing: Bool {
        guard let host, now.timeIntervalSince(host.beatAt) < LinkChannel.beatFreshness else { return false }
        return host.phase == .starting || host.phase == .listening
    }

    /// What tapping the mic key does now.
    var micMode: MicKeyMode {
        if let until = forcedOpenAppUntil, until > now, hasFullAccess() { return .openApp }
        return MicKeyMode.resolve(host: host, now: now, fullAccess: hasFullAccess())
    }

    /// What the open-app key asks of the app: to arm the microphone, not to dictate (the app is in front
    /// of the host app's field then). The dictation starts with the next tap, back in the host app.
    var openAppCommand: RequestCommand { MicKeyMode.openApp.request ?? .arm }

    /// The mic key was tapped. In `.openApp` mode the key is a `Link` that opens the app by itself; this
    /// sends the same request over the link, for an app that is already running.
    func micTapped() {
        reloadHost()
        let mode = micMode
        switch mode {
        case .needsFullAccess:
            trace?("mic mode=needsFullAccess")
            show("Turn on Allow Full Access for Legato in Settings > General > Keyboard to dictate.")
        case .openApp:
            trace?("mic mode=openApp")
            let id = openAppRequestID
            link.send(openAppCommand, id: id)
            Task { [weak self] in
                let result = await self?.link.awaitAck(id: id, timeout: LinkChannel.ackTimeout)
                self?.trace?("ack result=\(result?.rawValue ?? "timeout")")
            }
            // The Link reads its URL as the tap lands; a fresh id is for the next tap.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.openAppRequestID = UUID().uuidString
            }
        case .remote(let action):
            trace?("mic mode=remote-\(action == .start ? "start" : "stop")")
            Task { await sendRemote(action) }
        }
    }

    /// Asks the running app; without an ack in time (or an ack of `hop`) the key becomes an open-app
    /// key for a few seconds, because opening the app takes a real tap on the Link.
    private func sendRemote(_ action: RemoteAction) async {
        let id = UUID().uuidString
        link.send(action == .start ? .start : .stop, id: id)
        let result = await link.awaitAck(id: id, timeout: LinkChannel.ackTimeout)
        trace?("ack result=\(result?.rawValue ?? "timeout")")
        guard result != .accepted else {
            // "Accepted" is the app taking the request on; a start can still fail afterwards (the system
            // refused the microphone), and then the app answers the same request again with `hop`.
            if action == .start { await watchForFailedStart(id: id) }
            return
        }
        needsAppOpened()
    }

    /// Watches a start the app accepted until the run is listening, or the app says it could not start.
    private func watchForFailedStart(id: String) async {
        let deadline = ContinuousClock.now + .seconds(Self.startWatchSeconds)
        while ContinuousClock.now < deadline, isVisible {
            if let ack = link.readAck(), ack.id == id, ack.result == .hop {
                trace?("ack result=hop-after-accept")
                needsAppOpened()
                return
            }
            reloadHost()
            if let host, host.isLive(now: now), host.phase == .listening { return }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// How long a remote start is watched for failing after it was accepted.
    private static let startWatchSeconds = 8.0

    /// The app can't dictate from where it is: the mic key becomes an open-app key for a few seconds.
    private func needsAppOpened() {
        reloadHost()
        forcedOpenAppUntil = now.addingTimeInterval(5)
        openAppRequestID = UUID().uuidString
        show("Legato needs to open. Tap the mic again.")
    }

    /// The emoji key: the emoji panel lands later; for now it says so.
    func emojiTapped() {
        show("Emoji is coming soon.")
    }

    private func show(_ text: String) {
        hint = text
        hintTimeout?.cancel()
        hintTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hint = nil
        }
    }
}
