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
/// Defaults: summary on click (not automatic) with the sections Summary, Decisions and Action items ticked, backend
/// explicit Foundation Models, echo and noise cancellation LocalVQE, live and after-meeting diarization on, idle processing on, language
/// Auto, auto-mute on.
public struct MeetingSettings: Sendable {
    // UserDefaults is documented thread-safe but not annotated Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults

    private enum Key {
        static let prompt = "meeting.summaryPrompt"
        static let backend = "meeting.summaryBackend"
        static let voiceProcessing = "meeting.voiceProcessing"
        static let autoMute = "meeting.autoMute"
        static let claudeDisclosure = "meeting.claudeDisclosureAccepted"
        static let summarizeAutomatically = "meeting.summarizeAutomatically"
        static let sections = "meeting.sections"
        static let sectionOrder = "meeting.sectionOrder"
        static let defaultSections = "meeting.defaultSections"
        static let sectionsMigrated = "meeting.sectionsMigrated"
        // Before sections: the user's templates, the one new meetings used, and whether the old prompt moved in.
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
        CleanupSelectionMigration.migrate(defaults)
        self.defaults = defaults
    }

    /// The summary prompt from before templates existed. Kept so it can move into the "My notes" section
    /// (see ``customSections``); new instructions belong in sections.
    public var customPrompt: String {
        get { defaults.string(forKey: Key.prompt) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Key.prompt) }
    }

    /// Which on-device backend writes the automatic summary. Claude is never a choice here: it is explicit,
    /// per meeting.
    public var backend: CleanupBackendChoice {
        get { defaults.string(forKey: Key.backend).flatMap(CleanupBackendChoice.init(rawValue:)) ?? .coreML }
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

    // MARK: Summary

    /// Write the summary on its own after the meeting, once the other steps are done. Default off: the user
    /// names the speakers first and asks for it with Summarize.
    public var summarizeAutomatically: Bool {
        get { defaults.bool(forKey: Key.summarizeAutomatically) }
        nonmutating set { defaults.set(newValue, forKey: Key.summarizeAutomatically) }
    }

    // MARK: Summary sections

    /// The user's own sections, in the order they were made. An older install's custom templates, its pre-template
    /// prompt ("My notes") and its default template move in the first time sections are read, once.
    public var customSections: [SummarySection] {
        migrateTemplatesIfNeeded()
        return storedSections()
    }

    /// Every section, built in and custom, in the order the user gave them (new ones last).
    public var allSections: [SummarySection] {
        let all = SummarySection.builtIns + customSections
        let order = defaults.stringArray(forKey: Key.sectionOrder) ?? []
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return all.enumerated()
            .sorted { (rank[$0.element.id] ?? order.count + $0.offset) < (rank[$1.element.id] ?? order.count + $1.offset) }
            .map(\.element)
    }

    public func section(id: SectionID) -> SummarySection? { SummarySection.find(id, custom: customSections) }

    /// What a new meeting ticks, in the configured order; sections that are gone are left out. Default: Summary,
    /// Decisions, Action items.
    public var defaultSectionIDs: [SectionID] {
        get {
            let catalog = allSections
            let ids = defaults.stringArray(forKey: Key.defaultSections) ?? SummarySection.defaultIDs
            return SummarySection.resolve(ids, in: catalog).map(\.id)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.defaultSections) }
    }

    /// Adds a custom section under a new unique id; it goes last.
    @discardableResult
    public func addSection(heading: String, instruction: String) -> SummarySection {
        let made = SummarySection(id: "custom-\(UUID().uuidString.lowercased())", heading: heading, instruction: instruction)
        storeSections(customSections + [made])
        return made
    }

    /// Replaces the custom section with `section`'s id. Built-ins and unknown ids are left alone.
    public func updateSection(_ section: SummarySection) {
        var all = customSections
        guard let index = all.firstIndex(where: { $0.id == section.id }) else { return }
        all[index] = section
        storeSections(all)
    }

    /// Removes a custom section (from the default ticks too). Built-ins stay.
    public func deleteSection(id: SectionID) {
        let all = customSections
        guard all.contains(where: { $0.id == id }) else { return }
        storeSections(all.filter { $0.id != id })
    }

    /// Moves the sections at `source` (offsets in ``allSections``) to before `destination`, as a list's move does.
    public func moveSections(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ids = allSections.map(\.id)
        let moving = source.filter { $0 < ids.count }.map { ids[$0] }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) where index < ids.count { ids.remove(at: index) }
        ids.insert(contentsOf: moving, at: min(max(0, destination - before), ids.count))
        defaults.set(ids, forKey: Key.sectionOrder)
    }

    /// The sections a meeting's summary holds: its ticks (the default ticks when it has none of its own), in the
    /// configured order, without any that are gone.
    public func sections(for meeting: Meeting) -> [SummarySection] {
        let catalog = allSections
        return SummarySection.resolve(meeting.sections ?? defaultSectionIDs, in: catalog)
    }

    /// The meeting's ticks after its chip for `id` is tapped: ticked when it was not, unticked when it was, in the
    /// configured order.
    public func ticks(of meeting: Meeting, toggling id: SectionID) -> [SectionID] {
        var ticked = Set(sections(for: meeting).map(\.id))
        if ticked.contains(id) { ticked.remove(id) } else { ticked.insert(id) }
        return allSections.map(\.id).filter(ticked.contains)
    }

    private func storedSections() -> [SummarySection] {
        defaults.data(forKey: Key.sections).flatMap { try? JSONDecoder().decode([SummarySection].self, from: $0) } ?? []
    }

    private func storeSections(_ sections: [SummarySection]) {
        defaults.set(try? JSONEncoder().encode(sections), forKey: Key.sections)
    }

    /// A summary template as an older install stored it.
    private struct LegacyTemplate: Decodable {
        var id: String
        var name: String
        var prompt: String
    }

    /// Templates become sections, once: each custom template a custom section with its id ("My template" becomes
    /// "My notes"), the pre-template prompt "My notes" unless it already moved, and the default template the
    /// default ticks. Nothing to move leaves the migration open, so a prompt set later still moves.
    private func migrateTemplatesIfNeeded() {
        guard !defaults.bool(forKey: Key.sectionsMigrated) else { return }
        let templates = defaults.data(forKey: Key.templates).flatMap { try? JSONDecoder().decode([LegacyTemplate].self, from: $0) } ?? []
        var sections = storedSections()
        for template in templates where !sections.contains(where: { $0.id == SummarySection.sections(forTemplate: template.id).first }) {
            if template.id == SummarySection.legacyMigratedTemplateID {
                let heading = template.name == "My template" ? "My notes" : template.name
                sections.append(SummarySection(id: SummarySection.migratedID, heading: heading, instruction: template.prompt))
            } else if SummarySection.find(template.id, custom: []) == nil {
                sections.append(SummarySection(id: template.id, heading: template.name, instruction: template.prompt))
            }
        }
        var defaultTemplate = defaults.string(forKey: Key.defaultTemplate)
        if !defaults.bool(forKey: Key.templatesMigrated) {
            let before = sections.count
            sections = SummarySection.migratingLegacyPrompt(customPrompt, into: sections)
            // As before: the user's prompt keeps being used, unless they had picked a default.
            if sections.count > before, defaultTemplate == nil { defaultTemplate = SummarySection.legacyMigratedTemplateID }
        }
        guard !templates.isEmpty || defaultTemplate != nil || sections.count != storedSections().count else { return }
        storeSections(sections)
        if defaults.stringArray(forKey: Key.defaultSections) == nil, let defaultTemplate {
            defaults.set(SummarySection.sections(forTemplate: defaultTemplate), forKey: Key.defaultSections)
        }
        defaults.set(true, forKey: Key.sectionsMigrated)
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
