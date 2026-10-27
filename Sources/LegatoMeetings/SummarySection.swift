import Foundation

/// The id of a ``SummarySection``: a built-in's fixed id, or `custom-<uuid>` for the user's own.
public typealias SectionID = String

/// One part of a meeting summary: a heading and what the model writes under it.
///
/// Seven are built in (Summary, Decisions, Action items, Open questions, Email follow-up, 1:1 notes, Brainstorm);
/// the user adds their own in Settings. A meeting ticks any set of them (``Meeting/sections``), and its summary
/// holds exactly the ticked ones, each under `## <heading>`, in the order Settings gives them.
public struct SummarySection: Sendable, Equatable, Codable, Identifiable {
    public var id: SectionID
    /// What the section is called in the summary (`## <heading>`) and on its chip.
    public var heading: String
    /// What to write under the heading; ``MeetingSummarizer`` adds the frame, the language and the notes.
    public var instruction: String

    public init(id: SectionID, heading: String, instruction: String) {
        self.id = id
        self.heading = heading
        self.instruction = instruction
    }

    public var isBuiltIn: Bool { Self.builtIns.contains { $0.id == id } }

    // MARK: Built in

    public static let summary = SummarySection(
        id: "summary", heading: "Summary",
        instruction: "A short paragraph or a few bullets on what the meeting covered.")

    public static let decisions = SummarySection(
        id: "decisions", heading: "Decisions",
        instruction: "Bullets for each decision made. Write \"None.\" if there were none.")

    public static let actionItems = SummarySection(
        id: "action-items", heading: "Action items",
        instruction: "Bullets for each task, with the owner's name where it is clear. Write \"None.\" if there were none.")

    public static let openQuestions = SummarySection(
        id: "open-questions", heading: "Open questions",
        instruction: "Bullets for questions that were raised and not answered. Write \"None.\" if there were none.")

    public static let emailFollowUp = SummarySection(
        id: "email-follow-up", heading: "Email follow-up",
        instruction: """
            The follow-up email, ready to send: a "Subject:" line, a greeting, two or three sentences on what was \
            discussed, the decisions as bullets, the next steps as bullets with their owners and dates where named, \
            and a short closing.
            """)

    public static let oneOnOne = SummarySection(
        id: "one-on-one", heading: "1:1 notes",
        instruction: """
            Notes for a one-to-one conversation, as bold-labelled bullet groups: **Topics discussed** (one bullet per \
            topic, with the key points under it), **Feedback and concerns** (saying who raised them), **Commitments** \
            (what each person agreed to do) and **For next time** (what to pick up in the next conversation). Write \
            "None." for a group with nothing in it.
            """)

    public static let brainstorm = SummarySection(
        id: "brainstorm", heading: "Brainstorm",
        instruction: """
            A structured overview of the ideas, as bold-labelled bullet groups: **Ideas** (grouped by theme, each \
            idea in a few words, naming who suggested it where that is clear), **Most discussed** (the ideas the \
            group spent the most time on or liked best, and why) and **Next steps** (what was agreed to try or look \
            into next; "None." if nothing was).
            """)

    public static let builtIns: [SummarySection] = [
        summary, decisions, actionItems, openQuestions, emailFollowUp, oneOnOne, brainstorm,
    ]

    /// What a new meeting ticks until Settings say otherwise: Summary, Decisions and Action items.
    public static let defaultIDs: [SectionID] = [summary.id, decisions.id, actionItems.id]

    /// The section with `id`: a built-in first, then the user's.
    public static func find(_ id: SectionID, custom: [SummarySection]) -> SummarySection? {
        (builtIns + custom).first { $0.id == id }
    }

    /// The sections of `catalog` whose ids are in `ids`, in the catalog's order (the order Settings give them).
    /// Ids that are not in the catalog (a deleted custom section) are left out.
    public static func resolve(_ ids: [SectionID], in catalog: [SummarySection]) -> [SummarySection] {
        let wanted = Set(ids)
        return catalog.filter { wanted.contains($0.id) }
    }

    // MARK: Instructions

    private static func list(_ sections: [SummarySection]) -> String {
        sections.map { "## \($0.heading)\n\($0.instruction)" }.joined(separator: "\n\n")
    }

    /// The instructions for writing the summary document: exactly `sections`, in this order, each under its
    /// `## <heading>`.
    public static func instructions(for sections: [SummarySection]) -> String {
        """
        You write meeting notes from a transcript. Each line starts with the speaker's name and a timestamp; a \
        line with no name has an unknown speaker. Write in the same language as the transcript, as Markdown with \
        exactly these sections, in this order:

        \(list(sections))

        Use only what the transcript says. Do not invent names, dates or commitments.
        """
    }

    /// The instructions for one part of a long transcript: notes on what the part says for each of `sections`,
    /// which the merge step then writes up as the document.
    static func noteInstructions(for sections: [SummarySection]) -> String {
        """
        You take notes on one part of a longer meeting transcript; the notes on all the parts are combined into \
        the meeting's summary later. Each line starts with the speaker's name and a timestamp; a line with no name \
        has an unknown speaker. Write in the same language as the transcript. Under each of these "## " headings, \
        note as short bullets what this part says that belongs there, with names, owners and dates where they are \
        said. Leave out a heading this part says nothing for.

        \(list(sections))

        Use only what the transcript says. Do not invent names, dates, ideas or commitments.
        """
    }

    // MARK: Templates (before sections)

    /// The sections an older meeting's single template stands for: the Summary template is the default three,
    /// each other built-in its own section, "My template" the migrated "My notes", a custom template the custom
    /// section that took its id.
    public static func sections(forTemplate id: String) -> [SectionID] {
        switch id {
        case "summary": defaultIDs
        case legacyMigratedTemplateID: [migratedID]
        default: [id]  // action-items, email-follow-up, one-on-one, brainstorm, custom-…
        }
    }

    /// The id the pre-template prompt moved into while templates existed ("My template").
    public static let legacyMigratedTemplateID = "my-template"

    /// The id of the section an old custom prompt moves into, "My notes".
    public static let migratedID = "my-notes"

    /// The built-in Summary template's prompt before sections: an old custom prompt equal to it is no custom prompt.
    public static let legacyDefaultPrompt = """
        You write meeting notes from a transcript. Each line starts with the speaker's name and a timestamp; \
        a line with no name has an unknown speaker. Write in the same language as the transcript, as \
        Markdown with exactly these sections:

        ## Summary
        A short paragraph or a few bullets on what the meeting covered.

        ## Decisions
        Bullets for each decision made. Write "None." if there were none.

        ## Action items
        Bullets for each task, with the owner's name where it is clear. Write "None." if there were none.

        Use only what the transcript says. Do not invent names, dates or commitments.
        """

    /// `sections` with the pre-template `meeting.summaryPrompt` added as "My notes", when it is set and is not the
    /// old default. Safe to repeat: an existing "My notes" (even an edited one) is left alone.
    public static func migratingLegacyPrompt(_ prompt: String, into sections: [SummarySection]) -> [SummarySection] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != legacyDefaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            !sections.contains(where: { $0.id == migratedID })
        else { return sections }
        return sections + [SummarySection(id: migratedID, heading: "My notes", instruction: prompt)]
    }
}
