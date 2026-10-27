import Foundation
import LegatoClaude
import LegatoMeetings

/// What cleans the meeting microphone: LocalVQE, Apple's voice processing (Mac), or nothing.
public enum EchoNoiseMode: String, Sendable, Equatable, CaseIterable {
    case localVQE
    case appleVoiceProcessing
    case off
}

/// The meeting settings in an injected `UserDefaults` (the App Group's on the phone, the app's on the Mac).
/// Defaults: Summary template, backend Auto, echo and noise cancellation LocalVQE, live and after-meeting
/// diarization on, idle processing on, language Auto, auto-mute on.
public struct MeetingSettings: Sendable {
    // UserDefaults is documented thread-safe but not annotated Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults

    private enum Key {
        static let prompt = "meeting.summaryPrompt"
        static let backend = "meeting.summaryBackend"
        static let voiceProcessing = "meeting.voiceProcessing"
        static let autoMute = "meeting.autoMute"
        static let claudeDisclosure = "meeting.claudeDisclosureAccepted"
        static let templates = "meeting.templates"
        static let templatesMigrated = "meeting.templatesMigrated"
        static let defaultTemplate = "meeting.defaultTemplate"
        static let liveDiarization = "meeting.liveDiarization"
        static let offlineDiarization = "meeting.offlineDiarization"
        static let idleProcessing = "meeting.idleProcessing"
        static let language = "meeting.language"
        static let echoNoise = "meeting.echoNoise"
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The summary prompt from before templates existed. Kept so it can move into "My template"
    /// (see ``customTemplates``); new prompts belong in templates.
    public var customPrompt: String {
        get { defaults.string(forKey: Key.prompt) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Key.prompt) }
    }

    /// Which on-device backend writes the automatic summary. Claude is never a choice here: it is explicit,
    /// per meeting.
    public var backend: CleanupBackendChoice {
        get { defaults.string(forKey: Key.backend).flatMap(CleanupBackendChoice.init(rawValue:)) ?? .auto }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.backend) }
    }

    /// Whether the mic is cleaned at all (the old on/off toggle, kept for the settings views that still use it):
    /// ``echoNoise`` is not off. Turning it on from off picks the default method, LocalVQE; turning it off picks off.
    public var voiceProcessing: Bool {
        get { echoNoise != .off }
        nonmutating set {
            defaults.set(newValue, forKey: Key.voiceProcessing)
            if newValue { if echoNoise == .off { echoNoise = .localVQE } } else { echoNoise = .off }
        }
    }

    /// Mac: mute "me" when the call app closes the mic. Default on.
    public var autoMute: Bool {
        get { defaults.object(forKey: Key.autoMute) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.autoMute) }
    }

    /// The user has read what leaves the device when Claude summarises a meeting. Valid for one key:
    /// ``storeClaudeKey(_:in:)`` resets it.
    public var claudeDisclosureAccepted: Bool {
        get { defaults.bool(forKey: Key.claudeDisclosure) }
        nonmutating set { defaults.set(newValue, forKey: Key.claudeDisclosure) }
    }

    /// Stores `key` (trimmed) in `store`, or removes the key when it is empty, and forgets the disclosure:
    /// a new key or a removed one asks the user again. A store that fails changes nothing.
    public func storeClaudeKey(_ key: String, in store: any APIKeyStore) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { try store.deleteKey() } else { try store.save(apiKey: trimmed) }
        claudeDisclosureAccepted = false
    }

    // MARK: Summary templates

    /// The user's own templates, in the order they were made. The pre-template `meeting.summaryPrompt`, if the
    /// user set one, becomes "My template" the first time templates are read (see ``SummaryTemplate/migratingLegacyPrompt(_:into:)``)
    /// and the default template, so the prompt keeps being used; this happens once.
    public var customTemplates: [SummaryTemplate] {
        migrateLegacyPromptIfNeeded()
        return storedTemplates()
    }

    /// The five built-in templates, then the user's.
    public var allTemplates: [SummaryTemplate] { SummaryTemplate.builtIns + customTemplates }

    public func template(id: String) -> SummaryTemplate? { SummaryTemplate.find(id, custom: customTemplates) }

    /// The template new meetings use; Summary when none was chosen or the chosen one is gone.
    public var defaultTemplateID: String {
        get {
            _ = customTemplates
            let id = defaults.string(forKey: Key.defaultTemplate) ?? SummaryTemplate.summaryID
            return template(id: id) == nil ? SummaryTemplate.summaryID : id
        }
        nonmutating set { defaults.set(newValue, forKey: Key.defaultTemplate) }
    }

    /// Adds a custom template under a new unique id.
    @discardableResult
    public func addTemplate(name: String, prompt: String) -> SummaryTemplate {
        let made = SummaryTemplate(id: "custom-\(UUID().uuidString.lowercased())", name: name, prompt: prompt)
        storeTemplates(customTemplates + [made])
        return made
    }

    /// Replaces the custom template with `template`'s id. Built-ins and unknown ids are left alone.
    public func updateTemplate(_ template: SummaryTemplate) {
        var all = customTemplates
        guard let index = all.firstIndex(where: { $0.id == template.id }) else { return }
        all[index] = template
        storeTemplates(all)
    }

    /// Removes a custom template. Built-ins stay. A deleted "My template" is not made again from the old prompt.
    public func deleteTemplate(id: String) {
        let all = customTemplates
        guard all.contains(where: { $0.id == id }) else { return }
        storeTemplates(all.filter { $0.id != id })
        if id == SummaryTemplate.migratedID { defaults.set(true, forKey: Key.templatesMigrated) }
    }

    private func storedTemplates() -> [SummaryTemplate] {
        defaults.data(forKey: Key.templates).flatMap { try? JSONDecoder().decode([SummaryTemplate].self, from: $0) } ?? []
    }

    private func storeTemplates(_ templates: [SummaryTemplate]) {
        defaults.set(try? JSONEncoder().encode(templates), forKey: Key.templates)
    }

    private func migrateLegacyPromptIfNeeded() {
        guard !defaults.bool(forKey: Key.templatesMigrated) else { return }
        let stored = storedTemplates()
        let migrated = SummaryTemplate.migratingLegacyPrompt(customPrompt, into: stored)
        // Nothing to move (no prompt, or the default one): stay open, so a prompt set later still moves.
        guard migrated.count != stored.count else { return }
        storeTemplates(migrated)
        defaults.set(true, forKey: Key.templatesMigrated)
        if defaults.string(forKey: Key.defaultTemplate) == nil {
            defaults.set(SummaryTemplate.migratedID, forKey: Key.defaultTemplate)
        }
    }

    // MARK: Speakers, processing, language

    /// Tell speakers apart while the meeting records. Default on.
    public var liveDiarization: Bool {
        get { defaults.object(forKey: Key.liveDiarization) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.liveDiarization) }
    }

    /// The after-meeting speaker pass over the whole recording. Default on.
    public var offlineDiarization: Bool {
        get { defaults.object(forKey: Key.offlineDiarization) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.offlineDiarization) }
    }

    /// Wait for an idle machine before the heavy after-meeting steps. Default on; off runs them right after the
    /// meeting (still one at a time, at background priority).
    public var idleProcessing: Bool {
        get { defaults.object(forKey: Key.idleProcessing) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.idleProcessing) }
    }

    /// The meeting language last used (a locale identifier); nil is Auto, the default.
    public var language: String? {
        get { defaults.string(forKey: Key.language) }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: Key.language) } else { defaults.removeObject(forKey: Key.language) }
        }
    }

    /// What cleans the meeting microphone. Default LocalVQE. Until a choice is made the old
    /// ``voiceProcessing`` value decides: off stays off, on or unset is LocalVQE.
    public var echoNoise: EchoNoiseMode {
        get {
            if let raw = defaults.string(forKey: Key.echoNoise), let mode = EchoNoiseMode(rawValue: raw) { return mode }
            return defaults.object(forKey: Key.voiceProcessing) as? Bool == false ? .off : .localVQE
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.echoNoise) }
    }
}
