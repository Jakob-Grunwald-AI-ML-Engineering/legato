import Foundation
import LegatoMeetings

/// What Legato does when another app starts a call (it holds the mic and the speakers).
public enum CallDetectionMode: String, Sendable, CaseIterable {
    case off, prompt, autoRecord
}

/// The meeting settings in an injected `UserDefaults`. Defaults: the summary is written when a meeting ends,
/// with the sections Summary, Decisions and Action items ticked.
public struct MeetingSettings: Sendable {
    // UserDefaults is documented thread-safe but not annotated Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults

    private enum Key {
        static let summarizeAutomatically = "meeting.summarizeAutomatically"
        static let sections = "meeting.sections"
        static let sectionOrder = "meeting.sectionOrder"
        static let defaultSections = "meeting.defaultSections"
        static let callDetection = "meeting.callDetection"
        static let calendarTitles = "meeting.calendarTitles"
    }

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// Write the summary on its own once a meeting has stopped. Default on; off leaves it to Summarize.
    public var summarizeAutomatically: Bool {
        get { defaults.object(forKey: Key.summarizeAutomatically) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.summarizeAutomatically) }
    }

    /// What a call in another app does. Default off: nothing watches the microphone then.
    public var callDetection: CallDetectionMode {
        get { defaults.string(forKey: Key.callDetection).flatMap(CallDetectionMode.init(rawValue:)) ?? .off }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.callDetection) }
    }

    /// A new meeting takes the title and attendees of the calendar event happening now. Default off; it also needs
    /// the user's calendar access.
    public var calendarTitles: Bool {
        get { defaults.object(forKey: Key.calendarTitles) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Key.calendarTitles) }
    }

    // MARK: Summary sections

    /// The user's own sections, in the order they were made.
    public var customSections: [SummarySection] {
        defaults.data(forKey: Key.sections).flatMap { try? JSONDecoder().decode([SummarySection].self, from: $0) } ?? []
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
            let ids = defaults.stringArray(forKey: Key.defaultSections) ?? SummarySection.defaultIDs
            return SummarySection.resolve(ids, in: allSections).map(\.id)
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

    /// Removes a custom section. Built-ins stay.
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
        SummarySection.resolve(meeting.sections ?? defaultSectionIDs, in: allSections)
    }

    /// The meeting's ticks after its chip for `id` is tapped: ticked when it was not, unticked when it was, in the
    /// configured order.
    public func ticks(of meeting: Meeting, toggling id: SectionID) -> [SectionID] {
        var ticked = Set(sections(for: meeting).map(\.id))
        if ticked.contains(id) { ticked.remove(id) } else { ticked.insert(id) }
        return allSections.map(\.id).filter(ticked.contains)
    }

    private func storeSections(_ sections: [SummarySection]) {
        defaults.set(try? JSONEncoder().encode(sections), forKey: Key.sections)
    }
}
