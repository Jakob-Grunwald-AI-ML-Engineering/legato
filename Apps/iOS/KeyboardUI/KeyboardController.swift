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
    /// The versions of the last dictation that landed in this field (raw, cleaned, refinements), for the
    /// version keys; nil when there is none (a new run, the user typed, another field).
    private(set) var versions: DictationVersions?
    /// A refine request is waiting for the app.
    private(set) var isRefining = false

    @ObservationIgnored private var cursor: AppliedCursor?
    @ObservationIgnored private var isTornDown = false
    private var forcedOpenAppUntil: Date?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var reapply: Task<Void, Never>?
    @ObservationIgnored private var hintTimeout: Task<Void, Never>?

    init(document: any TextDocument, link: LinkClient, hasFullAccess: @escaping @MainActor () -> Bool) {
        self.document = document
        self.link = link
        self.hasFullAccess = hasFullAccess
        cursor = link.readApplied()
        host = link.readHost()
        link.observeHost { [weak self] in self?.hostDidChange() }
        typing = TypingModel(controller: self)
    }

    var fullAccess: Bool { hasFullAccess() }

    // MARK: Visibility

    /// The keyboard came on screen: beat presence once a second, and catch up with a run in progress.
    func appeared() {
        guard !isTornDown else { return }
        isVisible = true
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
        if let versions, versions.documentID != document.documentID { self.versions = nil }
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
        applyHost()
    }

    /// Brings the field in line with the host's text. Only while visible, and only for a run in
    /// progress or one this keyboard already follows: the last state of a run it never saw (an old
    /// dictation, seen again when the keyboard reappears) is not typed. A "running" state whose beat has
    /// gone stale belongs to an app that died: its text is not typed either.
    private func applyHost() {
        guard !isTornDown, isVisible, let host, host.isLive(now: Date()) else { return }
        if cursor?.runID != host.runID, host.phase == .idle { return }
        let before = cursor
        let plan = ProxyEditPlanner.plan(
            state: host, cursor: cursor, contextBefore: document.contextBefore, documentID: document.documentID)
        perform(plan.ops)
        if let updated = plan.cursor, updated != before {
            cursor = updated
            link.writeApplied(updated)
            if !plan.ops.isEmpty || updated.finalApplied {
                trace?("apply final=\(updated.finalApplied ? 1 : 0) replaced=\(updated.finalReplaced.map { $0 ? "1" : "0" } ?? "-")")
            }
        }
        updateVersions(host)
    }

    /// A new run drops the last dictation's versions; a run that landed here offers its own.
    private func updateVersions(_ host: HostState) {
        if host.phase != .idle {
            if versions != nil, host.runID != versions?.runID { versions = nil }
            return
        }
        guard host.isFinal, versions?.runID != host.runID,
              let landed = DictationVersions.landed(state: host, cursor: cursor)
        else { return }
        versions = landed
        trace?("versions count=\(landed.texts.count) current=\(landed.current)")
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
        versions = nil // the user moved on from the dictation
        beforeUserEdit()
        document.insert(text)
        afterUserEdit()
    }

    func deleteBackward() {
        versions = nil
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

    // MARK: Versions

    func showPreviousVersion() {
        guard let versions else { return }
        showVersion(at: versions.current - 1)
    }

    func showNextVersion() {
        guard let versions else { return }
        showVersion(at: versions.current + 1)
    }

    /// Swaps the dictation in the field for version `index`, only while the field still ends with the
    /// version shown now.
    private func showVersion(at index: Int) {
        guard var current = versions, current.texts.indices.contains(index) else { return }
        guard current.documentID == document.documentID,
              let ops = current.swapOps(to: index, contextBefore: document.contextBefore)
        else {
            trace?("version swap=refused")
            show("The text changed, so there is nothing to swap.")
            return
        }
        perform(ops)
        current.show(index)
        versions = current
        trace?("version index=\(index) of=\(current.texts.count)")
    }

    /// Asks the app for a stronger rewrite (its message style) of the raw dictation and shows it as a new
    /// version. The keyboard never runs a model itself; the app must be running (it acks at once).
    func refine() {
        guard let versions, !isRefining else { return }
        guard hasFullAccess() else {
            show("Turn on Allow Full Access for Legato in Settings > General > Keyboard to refine.")
            return
        }
        isRefining = true
        let id = UUID().uuidString
        let runID = versions.runID
        link.sendRefine(versions.texts[0], id: id)
        trace?("refine sent")
        Task { [weak self] in
            await self?.awaitRefinement(id: id, runID: runID)
            self?.isRefining = false
        }
    }

    private func awaitRefinement(id: String, runID: String) async {
        let ack = await link.awaitAck(id: id, timeout: LinkChannel.ackTimeout)
        guard ack == .accepted else {
            trace?("refine ack=\(ack?.rawValue ?? "timeout")")
            show("Open Legato to refine: it isn't running right now.")
            return
        }
        guard let reply = await link.awaitRefined(id: id, timeout: LinkChannel.refineTimeout) else {
            trace?("refine reply=timeout")
            show("Refine took too long.")
            return
        }
        guard let refined = reply.text else {
            trace?("refine reply=none")
            show("No better version.")
            return
        }
        guard var current = versions, current.runID == runID else { return }
        let index = current.add(refined)
        versions = current
        trace?("refine reply=text")
        showVersion(at: index)
    }

    // MARK: Status

    /// The top bar's dictation line: the live text while a `.hold` run listens (nothing is typed then),
    /// "Listening…" otherwise, "Cleaning up…" while a run with cleanup finishes.
    var dictationStatus: String? {
        guard let host, now.timeIntervalSince(host.beatAt) < LinkChannel.beatFreshness else { return nil }
        switch host.phase {
        case .starting, .listening:
            let live = host.committed + host.volatile
            guard host.delivery == .hold, !live.trimmingCharacters(in: .whitespaces).isEmpty else { return "Listening…" }
            return live.count > 90 ? "…" + live.suffix(90) : live
        case .finishing:
            return host.delivery == nil ? nil : "Cleaning up…"
        case .idle:
            return nil
        }
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
