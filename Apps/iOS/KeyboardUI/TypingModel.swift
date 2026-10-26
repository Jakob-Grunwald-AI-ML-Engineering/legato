import LegatoKeyboardCore
import Observation
import UIKit

/// What the key grid draws besides the layout.
struct KeyPresentation: Equatable {
    var uppercase = false
    var shift = ShiftState.Mode.off
    var returnLabel = "return"
    var returnEnabled = true
    var returnProminent = false
    var spaceLabel = "space"
}

/// The typing side of the keyboard: the page, shift, auto-capitalization, space and delete rules.
/// The rules live in LegatoKeyboardCore (tested there); this type applies them to the field through
/// `KeyboardController.type` / `deleteBackward`, so edits still make way for a dictation in progress.
///
/// The field's context settles a moment after an edit, so the text before the cursor is tracked
/// locally for `settleWindow` after each of our own edits and read from the field after that.
@MainActor @Observable
final class TypingModel {
    static let settleWindow: TimeInterval = 0.15

    /// Weak: the controller owns this model, and a view may briefly outlive the controller; a stale model
    /// then reads defaults and edits nothing, instead of trapping.
    @ObservationIgnored private weak var controller: KeyboardController?
    @ObservationIgnored let feedback = KeyFeedback()
    @ObservationIgnored var now: () -> Date = { Date() }

    private(set) var page = KeyboardPage.letters
    private(set) var shift = ShiftState()

    @ObservationIgnored private var lastField: KeyboardField?
    @ObservationIgnored private var lastSpaceAt: Date?
    @ObservationIgnored private var shadow: (text: String, at: Date)?
    @ObservationIgnored private var deleter = DeleteRepeater()
    @ObservationIgnored private var deleteTask: Task<Void, Never>?
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    init(controller: KeyboardController) {
        self.controller = controller
    }

    // MARK: What to draw

    var field: KeyboardField { KeyboardField(controller?.keyboardType ?? .default) }

    var layout: TypingLayout { .make(page: page, field: field, showsGlobe: controller?.showsGlobe ?? false) }

    var presentation: KeyPresentation {
        KeyPresentation(
            uppercase: page == .letters && shift.isUppercase,
            shift: shift.mode,
            returnLabel: KeyLabels.returnLabel(controller?.returnKeyType ?? .default),
            returnEnabled: returnEnabled,
            returnProminent: (controller?.returnKeyType ?? .default) != .default,
            spaceLabel: KeyLabels.spaceLabel())
    }

    private var returnEnabled: Bool {
        guard controller?.enablesReturnKeyAutomatically == true else { return true }
        if let shadow, now().timeIntervalSince(shadow.at) < Self.settleWindow, !shadow.text.isEmpty { return true }
        return controller?.hasText ?? false
    }

    /// What the key types now (a letter is uppercase while shift is on); nil for non-character keys.
    func output(of key: Key) -> String? {
        key.output(uppercase: page == .letters && shift.isUppercase)
    }

    /// Long-press alternates of `key` as typed now.
    func alternates(for key: Key) -> [String] {
        guard let own = output(of: key) else { return [] }
        if field == .phonePad && own == "+" { return ["*", "#"] }
        return Alternates.for(own)
    }

    /// The suggestion slots (three, left to right); the prediction engine fills them later.
    var suggestions: [String] { controller?.suggestions ?? [] }

    // MARK: Lifecycle

    func appeared() {
        feedback.refresh(fullAccess: controller?.fullAccess ?? false)
        documentChanged()
    }

    func disappeared() {
        endDelete()
        settleTask?.cancel()
    }

    /// The field or its traits changed: a new field starts on its own page.
    func documentChanged() {
        let field = field
        if field != lastField {
            lastField = field
            page = controller?.keyboardType == .numbersAndPunctuation ? .numbers : .letters
        }
        refreshAutoShift()
    }

    /// Text changed behind our back (a dictation, the host): forget the local context.
    func hostEdited() {
        shadow = nil
        afterEdit()
    }

    /// Back to the letters page with nothing typed (the DEBUG harness clears its field with this).
    func reset() {
        endDelete()
        page = .letters
        shift = ShiftState()
        lastSpaceAt = nil
        shadow = nil
        refreshAutoShift()
    }

    // MARK: Keys

    /// A full tap on the key with this `Key.id`, for the scripted check and VoiceOver.
    @discardableResult
    func press(keyID: String) -> Bool {
        guard let key = layout.rows.lazy.flatMap(\.keys).first(where: { $0.id == keyID }) else { return false }
        keyDown(key)
        keyUp(key)
        return true
    }

    /// Delete acts on touch-down and repeats while held; every other key acts on `keyUp`.
    func keyDown(_ key: Key) {
        guard key.action == .delete else { return }
        beginDelete()
    }

    /// Delete once now, then repeat while held (`DeleteRepeater`) until `endDelete`. The strip's delete key uses it too.
    func beginDelete() {
        deleteOne()
        afterEdit()
        deleter.begin(at: now())
        deleteTask?.cancel()
        deleteTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                self?.tickDelete()
            }
        }
    }

    /// The return key's tap, as on the full keyboard: a newline, unless the field disables return (empty field).
    func tapReturn() {
        guard returnEnabled else { return }
        insert("\n")
        lastSpaceAt = nil
        afterEdit()
    }

    /// The touch lifted over `key`. `alternate` is the long-press pick, which replaces the key's output.
    func keyUp(_ key: Key, alternate: String? = nil) {
        switch key.action {
        case .character(let c):
            let text = alternate ?? (page == .letters && shift.isUppercase ? c.uppercased() : c)
            insert(text)
            if page == .letters, text.first?.isLetter == true { shift.didTypeLetter() }
            lastSpaceAt = nil
            afterEdit()
        case .space:
            typeSpace()
            afterEdit()
        case .returnKey:
            tapReturn()
        case .delete:
            endDelete()
        case .shift:
            shift.tapShift(at: now())
        case .modeSwitch(let target):
            page = target
            refreshAutoShift()
        case .emoji:
            controller?.emojiTapped()
        case .globe, .mic:
            break
        }
    }

    /// The touch ended without a key (slid off, or the system cancelled it).
    func keyCancelled(_ key: Key) {
        if key.action == .delete { endDelete() }
    }

    // MARK: Editing

    private func typeSpace() {
        let t = now()
        switch SpaceRules.spaceTapped(context: context(), lastSpaceAt: lastSpaceAt, now: t) {
        case .insertSpace:
            insert(" ")
            lastSpaceAt = t
        case .replacePreviousSpaceWithPeriodSpace:
            deleteOne()
            insert(". ")
            lastSpaceAt = nil
        }
    }

    private func insert(_ text: String) {
        let before = context().before
        controller?.type(text)
        shadow = (before + text, now())
    }

    private func deleteOne() {
        let before = context().before
        controller?.deleteBackward()
        shadow = (String(before.dropLast()), now())
        lastSpaceAt = nil
    }

    /// Deletes the word before the cursor with the spaces after it.
    private func deleteWord() {
        var count = 0
        var seenWord = false
        for ch in context().before.reversed() {
            if ch == " " || ch == "\t" {
                if seenWord { break }
            } else if ch.isNewline {
                break
            } else {
                seenWord = true
            }
            count += 1
        }
        for _ in 0..<max(count, 1) { deleteOne() }
    }

    private func tickDelete() {
        let due = deleter.tick(at: now())
        guard !due.isEmpty else { return }
        for action in due {
            switch action {
            case .character: deleteOne()
            case .word: deleteWord()
            }
        }
        afterEdit()
    }

    func endDelete() {
        deleter.end()
        deleteTask?.cancel()
        deleteTask = nil
    }

    // MARK: Context

    private func context() -> TextContext {
        if let shadow, now().timeIntervalSince(shadow.at) < Self.settleWindow {
            return TextContext(documentContextBeforeInput: shadow.text)
        }
        shadow = nil
        return TextContext(documentContextBeforeInput: controller?.document.contextBefore ?? "")
    }

    private func refreshAutoShift() {
        let type = controller?.autocapitalization ?? .none
        shift.applyAutoCapitalization(AutoCapitalizer.shouldCapitalize(type, context: context()))
    }

    /// After an edit: apply the rules now against the local context, and again once the field's has settled.
    private func afterEdit() {
        refreshAutoShift()
        controller?.refreshTraits()
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.settleWindow + 0.03))
            guard !Task.isCancelled, let self else { return }
            self.shadow = nil
            self.refreshAutoShift()
            self.controller?.refreshTraits()
        }
    }
}
