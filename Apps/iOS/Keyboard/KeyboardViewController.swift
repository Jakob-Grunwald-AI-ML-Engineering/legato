import LegatoKeyboardCore
import SwiftUI
import UIKit
import os

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

    private static let portraitHeight = KeyGeometry.height(landscape: false)
    private static let landscapeHeight = KeyGeometry.height(landscape: true)
    /// A height change animates over this.
    private static let resizeDuration = 0.28

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
        #if DEBUG
        // Debug: the controller's trace in the log (`defaults write <keyboard bundle> LegatoWindowProbe -bool YES`).
        if UserDefaults.standard.bool(forKey: "LegatoWindowProbe") {
            let logger = Logger(subsystem: "de.gruenwald.legato", category: "probe")
            controller.trace = { logger.debug("trace \($0, privacy: .public)") }
        }
        #endif
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

    /// The height the keyboard asks for: the pre-offshoot keyboard (word row, tool row, native grid), 297 pt in portrait. By width, as
    /// `KeyGeometry` does: a portrait keyboard (402 x 297) is wider than tall too.
    private var requestedHeight: CGFloat {
        KeyGeometry.isLandscape(width: view.bounds.width) ? Self.landscapeHeight : Self.portraitHeight
    }

    /// The strip height changed (the chevron, the setting): resize
    /// with the content's cross-fade, and log the height asked for against the one laid out.
    private func layoutChanged(reason: String) {
        #if DEBUG
        KeyboardGeometryLog.observeMotion(view: view)
        #endif
        heightConstraint?.constant = requestedHeight
        let settle: UIView = view.superview ?? view
        #if DEBUG
        UIView.animate(withDuration: Self.resizeDuration, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: { settle.layoutIfNeeded() }, completion: { [weak self] _ in
            guard let self else { return }
            KeyboardGeometryLog.reportResize(
                reason: reason, mode: modeName, requested: requestedHeight, view: view, inputView: inputView)
        })
        #else
        UIView.animate(withDuration: Self.resizeDuration, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) { settle.layoutIfNeeded() }
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
            NSLog("kbd.system-switch request=automatic-autofill field=%@ keyboard=%ld secure=%d",
                  AutoFillContentType.semanticName(for: controller.document.textContentType) ?? "none",
                  controller.document.keyboardType.rawValue, controller.document.isSecureTextEntry ? 1 : 0)
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
        let wanted = requestedHeight
        if heightConstraint?.constant != wanted { heightConstraint?.constant = wanted }
    }

    #if DEBUG
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        KeyboardGeometryLog.reportView(view, inputView: inputView, heightConstraint: heightConstraint, mode: modeName)
    }
    #endif

    override func textWillChange(_ textInput: (any UITextInput)?) {
        super.textWillChange(textInput)
        controller?.documentCallback("textWillChange")
    }

    override func selectionWillChange(_ textInput: (any UITextInput)?) {
        super.selectionWillChange(textInput)
        controller?.documentCallback("selectionWillChange")
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        controller?.documentCallback("textDidChange")
        controller?.documentDidChange()
        switchForAutoFillIfNeeded()
    }

    /// The cursor or the selection moved (a tap in the text): the word row looks at the word there. Some hosts
    /// report only `textDidChange`, which comes to the same handler.
    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        controller?.documentCallback("selectionDidChange")
        controller?.documentDidChange()
        switchForAutoFillIfNeeded()
    }
}

/// The input view. Adopting `UIInputViewAudioFeedback` lets `UIDevice.playInputClick()` click (the system's
/// Keyboard Clicks switch still applies; `KeyFeedback` calls it only with Full Access and the setting on).
final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
