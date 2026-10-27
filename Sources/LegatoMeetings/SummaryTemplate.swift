import Foundation

/// Instructions for one kind of meeting summary: what the model is asked to write.
///
/// Five templates are built in (Summary, Action items, Email follow-up, 1:1 notes, Brainstorm); the user
/// adds their own. A meeting stores the id of the template it was summarised with
/// (``Meeting/templateID``), and its summaries are filed by that id (``MeetingStore``).
public struct SummaryTemplate: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// The instructions sent with every request; ``MeetingSummarizer`` adds the language and the notes.
    public var prompt: String

    public init(id: String, name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }

    public var isBuiltIn: Bool { Self.builtIns.contains { $0.id == id } }

    // MARK: Built in

    /// The template new meetings use.
    public static let summaryID = "summary"

    public static let summary = SummaryTemplate(
        id: summaryID, name: "Summary",
        prompt: """
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
            """)

    public static let actionItems = SummaryTemplate(
        id: "action-items", name: "Action items",
        prompt: """
            You list the tasks that came out of a meeting transcript. Each line starts with the speaker's name \
            and a timestamp. Write in the same language as the transcript, as Markdown with exactly these \
            sections:

            ## Action items
            One checklist item per task: "- [ ] Owner: the task (due date if one was named)". Use the name of \
            the person who took the task on; write "Unassigned" where no one did. Write "None." if there were none.

            ## Open questions
            Bullets for questions that were raised and not answered. Write "None." if there were none.

            Use only what the transcript says. Do not invent names, dates or commitments.
            """)

    public static let emailFollowUp = SummaryTemplate(
        id: "email-follow-up", name: "Email follow-up",
        prompt: """
            You write the follow-up email for a meeting, from its transcript. Each line starts with the \
            speaker's name and a timestamp. Write in the same language as the transcript, as plain Markdown \
            ready to send:

            A "Subject:" line, a greeting, two or three sentences on what was discussed, the decisions as \
            bullets, the next steps as bullets with their owners and dates where named, and a short closing.

            Use only what the transcript says. Do not invent names, dates or commitments.
            """)

    public static let oneOnOne = SummaryTemplate(
        id: "one-on-one", name: "1:1 notes",
        prompt: """
            You write notes for a one-to-one conversation from its transcript. Each line starts with the \
            speaker's name and a timestamp. Write in the same language as the transcript, as Markdown with \
            exactly these sections:

            ## Topics discussed
            Bullets, one per topic, with the key points under it.

            ## Feedback and concerns
            Bullets for feedback given and concerns raised, saying who raised them. Write "None." if there were none.

            ## Commitments
            Bullets for what each person agreed to do. Write "None." if there were none.

            ## For next time
            Bullets for what to pick up in the next conversation. Write "None." if there is nothing.

            Use only what the transcript says. Do not invent names, dates or commitments.
            """)

    public static let brainstorm = SummaryTemplate(
        id: "brainstorm", name: "Brainstorm",
        prompt: """
            You turn a brainstorming session's transcript into a structured overview. Each line starts with \
            the speaker's name and a timestamp. Write in the same language as the transcript, as Markdown \
            with exactly these sections:

            ## Ideas
            Bullets grouped by theme, each idea in a few words, naming who suggested it where that is clear.

            ## Most discussed
            The ideas the group spent the most time on or liked best, and why.

            ## Open questions
            Bullets for questions left open. Write "None." if there were none.

            ## Next steps
            Bullets for what was agreed to try or look into next. Write "None." if there were none.

            Use only what the transcript says. Do not invent ideas, names or commitments.
            """)

    public static let builtIns: [SummaryTemplate] = [summary, actionItems, emailFollowUp, oneOnOne, brainstorm]

    /// The template with `id`: a built-in first, then the user's.
    public static func find(_ id: String, custom: [SummaryTemplate]) -> SummaryTemplate? {
        (builtIns + custom).first { $0.id == id }
    }

    // MARK: Migration

    /// The id of the template an old custom prompt moves into.
    public static let migratedID = "my-template"

    /// `templates` with the pre-template `meeting.summaryPrompt` added as "My template", when it is set and
    /// is not the default. Safe to repeat: an existing "My template" (even an edited one) is left alone.
    public static func migratingLegacyPrompt(_ prompt: String, into templates: [SummaryTemplate]) -> [SummaryTemplate] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != summary.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            !templates.contains(where: { $0.id == migratedID })
        else { return templates }
        return templates + [SummaryTemplate(id: migratedID, name: "My template", prompt: prompt)]
    }
}
