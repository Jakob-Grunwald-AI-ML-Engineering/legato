import AppIntents
import Foundation

/// The Live Activity's Insert button (result state): hands the dictated text to the Legato keyboard, which
/// types it into the field it is showing.
///
/// `LiveActivityIntent` makes `perform()` run in the app process, never in the widget process that
/// triggered it. This file compiles into the app and the widget extension; the app-only part sits inside
/// `#if APP_TARGET`, and the widget copy refuses to run.
struct InsertDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Insert dictation"
    static let description = IntentDescription("Types the last dictation into the field of the Legato keyboard.")
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard runsInApp else { throw ToggleDictationError.appRequired }
        #if APP_TARGET
        await AppController.shared.insertResult()
        #endif
        return .result()
    }
}

/// The Live Activity's Copy button (result state): puts the dictated text on the clipboard, from the
/// background. Same process rules as `InsertDictationIntent`.
struct CopyDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Copy dictation"
    static let description = IntentDescription("Copies the last dictation to the clipboard.")
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard runsInApp else { throw ToggleDictationError.appRequired }
        #if APP_TARGET
        await AppController.shared.copyResult()
        #endif
        return .result()
    }
}

private var runsInApp: Bool {
    #if APP_TARGET
    true
    #else
    false
    #endif
}
