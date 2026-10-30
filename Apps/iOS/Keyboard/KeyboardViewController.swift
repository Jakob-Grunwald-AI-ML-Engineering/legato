import LegatoKeyboardCore
import SwiftUI
import UIKit

/// The Legato keyboard. A `.keyboard`-style input view hosting the SwiftUI key grid. It compiles only
/// `Keyboard/` and `KeyboardUI/` (never `Shared/`: the AppIntents there would run in this process,
/// which cannot record) and links only `LegatoKeyboardCore` and `LegatoVocabulary` (the word row). Dictation
/// runs in the app; this process asks for it over the App Group and types the text the app publishes.
final class KeyboardViewController: UIInputViewController {
    // Shared across controller recreation when the user returns to Legato on the same field.
    private static var autoFillHandoff = AutoFillHandoff()
    private var handoffVisible = false
    private var controller: KeyboardController?
    private var heightConstraint: NSLayoutConstraint?
    private var heightDisplayLink: CADisplayLink?
    private var heightAnimationStart = 0.0
    private var heightAnimationFrom: CGFloat = 0
    private var heightAnimationTarget: CGFloat = 0
    #if DEBUG
    private var heightAnimationSamples: [[String: Double]] = []
    #endif

    private static let portraitHeight = KeyGeometry.height(landscape: false)
    private static let landscapeHeight = KeyGeometry.height(landscape: true)

    override func loadView() {
        let input = KeyboardInputView(frame: .zero, inputViewStyle: .keyboard)
        input.allowsSelfSizing = true
        inputView = input
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Weak: the proxy is read whenever a Darwin note arrives, which can be after this view controller
        // went away; the document then reads as "no field" (see `ProxyDocument`).
        let document = ProxyDocument(proxy: { [weak self] in self?.textDocumentProxy })
        let controller = KeyboardController(
            document: document, link: LinkClient(), hasFullAccess: { [weak self] in self?.hasFullAccess ?? false })
        controller.inputModeTarget = self
        controller.showsGlobe = needsInputModeSwitchKey
        self.controller = controller

        let host = UIHostingController(rootView: KeyboardRootView(controller: controller))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        // Priority 999: the system's own height constraint at 1000 must be able to win without a
        // layout-conflict log.
        let height = view.heightAnchor.constraint(equalToConstant: requestedHeight)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        heightConstraint = height
        controller.onLayoutChange = { [weak self] reason in self?.layoutChanged(reason: reason) }
    }

    /// The height the current mode asks for: the native tool row plus the prediction row above it, or the full keyboard's for the orientation. By width, as `KeyGeometry` does: a portrait
    /// keyboard (402 x 297) is wider than tall too.
    private var requestedHeight: CGFloat {
        let screenHeight = view.window?.windowScene?.screen.bounds.height ?? 874
        let landscape = KeyGeometry.isLandscape(width: view.bounds.width)
        // The observed native tray ends 75 pt below our portrait view (21 pt landscape).
        // Once laid out, measure that gap instead of adding the tray on top of an 85% request.
        var bottomTray: CGFloat = landscape ? 21 : 75
        if let window = view.window, view.bounds.height > 0 {
            let bottom = view.convert(view.bounds, to: window).maxY + window.frame.minY
            let gap = screenHeight - bottom
            if (0...150).contains(gap) { bottomTray = gap }
        }
        let overhead = bottomTray + (landscape ? 0 : WordRowHeight.portraitSystemTop)
        return CGFloat((controller?.composerSize ?? .medium).height(
            screenHeight: screenHeight, systemOverhead: overhead, landscape: landscape))
    }

    /// The mode or the strip height changed (the chevron, the debug height cycle, the setting): resize
    /// with the content's cross-fade, and log the height asked for against the one laid out.
    private func layoutChanged(reason: String) {
        if reason == "composer-resize" { animateHeight(to: requestedHeight); return }
        stopHeightAnimation(completed: false)
        heightConstraint?.constant = requestedHeight
        let settle: UIView = view.superview ?? view
        #if DEBUG
        UIView.animate(withDuration: 0.2, animations: { settle.layoutIfNeeded() }, completion: { [weak self] _ in
            guard let self else { return }
            KeyboardGeometryLog.reportResize(
                reason: reason, mode: modeName, requested: requestedHeight, view: view, inputView: inputView)
        })
        #else
        UIView.animate(withDuration: 0.2) { settle.layoutIfNeeded() }
        #endif
    }

    /// Native keyboard hosts can ignore a UIView animation transaction around a single height jump.
    /// Feed them bounded intermediate heights after the user selects one preset, never during a swipe.
    private func animateHeight(to target: CGFloat) {
        let current = view.bounds.height > 0 ? view.bounds.height : heightConstraint?.constant ?? target
        stopHeightAnimation(completed: false)
        heightAnimationFrom = current
        heightAnimationTarget = target
        heightAnimationStart = CACurrentMediaTime()
        heightConstraint?.constant = current
        let link = CADisplayLink(target: self, selector: #selector(stepHeightAnimation(_:)))
        heightDisplayLink = link
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
    }

    @objc private func stepHeightAnimation(_ link: CADisplayLink) {
        let progress = min(1, max(0, (link.timestamp - heightAnimationStart) / 0.28))
        let eased = 1 - pow(1 - progress, 3)
        let height = heightAnimationFrom + (heightAnimationTarget - heightAnimationFrom) * eased
        var ancestor: UIView = view
        while let parent = ancestor.superview { ancestor = parent }
        UIView.performWithoutAnimation {
            heightConstraint?.constant = height
            ancestor.layoutIfNeeded()
            view.layoutIfNeeded()
        }
        #if DEBUG
        heightAnimationSamples.append([
            "elapsed": link.timestamp - heightAnimationStart, "requested": height,
            "actual": view.bounds.height, "presentation": view.layer.presentation()?.bounds.height ?? view.bounds.height,
            "window": view.window?.bounds.height ?? 0,
        ])
        #endif
        if progress >= 1 { stopHeightAnimation(completed: true) }
    }

    private func stopHeightAnimation(completed: Bool) {
        heightDisplayLink?.invalidate()
        heightDisplayLink = nil
        #if DEBUG
        if !heightAnimationSamples.isEmpty {
            // Geometry only. Write once after animation, never on a display-link tick.
            if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LinkChannel.appGroupID),
               let data = try? JSONSerialization.data(withJSONObject: [
                "from": heightAnimationFrom, "to": heightAnimationTarget,
                "completed": completed, "frames": heightAnimationSamples,
               ], options: [.sortedKeys]) {
                let cache = group.appendingPathComponent("Library/Caches", isDirectory: true)
                try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                try? data.write(to: cache.appendingPathComponent("composer-height-animation.json"), options: .atomic)
            }
            heightAnimationSamples.removeAll(keepingCapacity: true)
        }
        #endif
    }

    private var modeName: String { controller?.mode == .strip ? "strip" : "full" }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        controller?.showsGlobe = needsInputModeSwitchKey
        controller?.appeared()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handoffVisible = true
        controller?.refreshTraits()
        switchForAutoFillIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        handoffVisible = false
        stopHeightAnimation(completed: false)
        heightConstraint?.constant = requestedHeight
        super.viewWillDisappear(animated)
    }

    /// Only field metadata is inspected; handing off does not type, read a password or start dictation.
    private func switchForAutoFillIfNeeded() {
        guard let controller else { return }
        if Self.autoFillHandoff.shouldSwitch(
            documentID: controller.document.documentID,
            contentType: AutoFillContentType.semanticName(for: controller.document.textContentType),
            enabled: KeyboardPreferences.load().automaticAutoFill,
            visible: handoffVisible && viewIfLoaded?.window != nil,
            targetAvailable: controller.inputModeTarget === self
        ) {
            #if DEBUG
            NSLog("kbd.autofill automatic-handoff")
            #endif
            advanceToNextInputMode()
        }
    }

    /// The controller observes the app's Darwin notes and runs tasks of its own; a hosting view can keep it
    /// alive a moment past this view controller, so it is shut down here, not left to its own release.
    isolated deinit {
        controller?.tearDown()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        controller?.disappeared()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        guard heightDisplayLink == nil else { return }
        let wanted = requestedHeight
        if heightConstraint?.constant != wanted { heightConstraint?.constant = wanted }
    }

    #if DEBUG
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        KeyboardGeometryLog.reportView(view, inputView: inputView, heightConstraint: heightConstraint, mode: modeName)
    }
    #endif

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        controller?.documentDidChange()
        switchForAutoFillIfNeeded()
    }

    /// The cursor or the selection moved (a tap in the text): the word row looks at the word there. Some hosts
    /// report only `textDidChange`, which comes to the same handler.
    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        controller?.documentDidChange()
        switchForAutoFillIfNeeded()
    }
}

/// The input view. Adopting `UIInputViewAudioFeedback` lets `UIDevice.playInputClick()` click (the system's
/// Keyboard Clicks switch still applies; `KeyFeedback` calls it only with Full Access and the setting on).
final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
