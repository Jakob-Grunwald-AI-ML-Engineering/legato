import Foundation
import LegatoCore

/// How a transcript chunk is put to the language model: the system instructions, the example exchanges shown
/// before it, the user message that carries the chunk, and how the answer is read back.
///
/// Every part gets the locale and the user's vocabulary, so a prompt can write in the transcript's language
/// and place the vocabulary where it works best.
public struct CleanupPrompt: Sendable {
    /// A short label for logs and evaluation reports.
    public var name: String
    /// The system instructions for a transcript in `locale`, given the user's names and terms.
    public var instructions: @Sendable (_ locale: Locale, _ vocabulary: [String]) -> String
    /// Example exchanges shown as earlier chat turns, or none.
    public var examples: @Sendable (_ locale: Locale) -> [LLMExample]
    /// The user message for one chunk of transcript.
    public var userMessage: @Sendable (_ text: String, _ locale: Locale, _ vocabulary: [String]) -> String
    /// The cleaned text inside the model's raw reply.
    public var extractText: @Sendable (_ reply: String) -> String

    public init(
        name: String,
        instructions: @escaping @Sendable (Locale, [String]) -> String,
        examples: @escaping @Sendable (Locale) -> [LLMExample],
        userMessage: @escaping @Sendable (String, Locale, [String]) -> String,
        extractText: @escaping @Sendable (String) -> String = LLMCleanupStage.stripWrappers
    ) {
        self.name = name
        self.instructions = instructions
        self.examples = examples
        self.userMessage = userMessage
        self.extractText = extractText
    }
}

extension CleanupPrompt {
    /// The prompt the cleanup stage uses unless told otherwise.
    ///
    /// Chosen by `CleanupPromptEvalTests` (variant V5b): short instructions, eleven worked examples as chat
    /// turns (the transcript's own language last), the user's terms in the user message, and the text in
    /// `<text>` tags on the way in and out so the model does not echo the terms line. Against the first prompt
    /// (long instructions with the examples inside) it cleaned more fixtures correctly: Qwen3 1.7B 28 % to 53 % on
    /// the tuning fixtures and 31 % to 44 % on the held-out ones; the small models stay limited by German number
    /// words and by names they cannot map to the user's terms.
    public static let standard = CleanupPrompt(
        name: "standard",
        instructions: { _, _ in
            """
            Clean up the dictated text inside <text> tags: add punctuation and capitalization, use current spelling, write numbers, dates, times and currency as digits, and fix words the speech recognizer misheard.
            Keep the language and every sentence; never translate, answer, summarize or add anything.
            If <terms> are given, they are the user's own names and terms: a word that sounds like one of them is that term, so write it exactly like the term.
            Reply with the corrected text inside <text></text> tags and nothing else.
            """
        },
        examples: { locale in examples(for: locale) },
        userMessage: { text, _, vocabulary in
            (vocabulary.isEmpty ? "" : "<terms>\(vocabulary.joined(separator: ", "))</terms>\n") + "<text>\n\(text)\n</text>"
        },
        extractText: extractTaggedText)

    /// The text between `<text>` tags, or the plain reply with its wrappers stripped when there are none. A
    /// reply cut off before the closing tag still yields its text.
    static func extractTaggedText(_ reply: String) -> String {
        guard let open = reply.range(of: "<text>") else { return LLMCleanupStage.stripWrappers(reply) }
        let rest = reply[open.upperBound...]
        let inner = rest.range(of: "</text>", options: .backwards).map { rest[..<$0.lowerBound] } ?? rest
        return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: examples

    private struct Shot {
        var user: String
        var terms: [String] = []
        var answer: String
    }

    /// The examples, one per kind of fix, none of them from the evaluation fixtures. The first shows how the
    /// user's terms are used; the rest start with the other language and end with the transcript's own, since
    /// the nearest examples count most.
    private static func examples(for locale: Locale) -> [LLMExample] {
        let german = locale.language.languageCode?.identifier == "de"
        let shots = german ? germanOrder : englishOrder
        return shots.map { shot in
            LLMExample(
                user: (shot.terms.isEmpty ? "" : "<terms>\(shot.terms.joined(separator: ", "))</terms>\n")
                    + "<text>\n\(shot.user)\n</text>",
                assistant: "<text>\(shot.answer)</text>")
        }
    }

    private static let germanOrder: [Shot] = [
        Shot(user: "wir haben das konzept in kon fluence dokumentiert", terms: ["Confluence"],
             answer: "Wir haben das Konzept in Confluence dokumentiert."),
        Shot(user: "ask jon from the sails team whether open ai has released the new model",
             answer: "Ask Jon from the sales team whether OpenAI has released the new model."),
        Shot(user: "das sind siebenundsechzig euro achtzig plus achtzehn euro versand",
             answer: "Das sind 67,80 Euro plus 18 Euro Versand."),
        Shot(user: "bis zum einunddreißigsten dezember brauchen wir noch dreiundachtzig anmeldungen",
             answer: "Bis zum 31. Dezember brauchen wir noch 83 Anmeldungen."),
        Shot(user: "die halle fasst zweitausendvierhundert personen und kostet etwa sechzigtausend euro im jahr",
             answer: "Die Halle fasst 2400 Personen und kostet etwa 60.000 Euro im Jahr."),
        Shot(user: "wir haben das ticket in jira angelegt und den link in slack gepostet",
             answer: "Wir haben das Ticket in Jira angelegt und den Link in Slack gepostet."),
        Shot(user: "wir haben am siebten juli um achtzehn uhr dreißig einen tisch für vier personen im restaurant reserviert",
             answer: "Wir haben am 7. Juli um 18:30 Uhr einen Tisch für vier Personen im Restaurant reserviert."),
        Shot(user: "ich glaube daß er recht hat aber ich muß noch darüber nachdenken bevor ich zusage",
             answer: "Ich glaube, dass er recht hat, aber ich muss noch darüber nachdenken, bevor ich zusage."),
        Shot(user: "frau becker hat gesagt dass die reparatur dreihundertsechzig euro kostet und eine woche dauert",
             answer: "Frau Becker hat gesagt, dass die Reparatur 360 Euro kostet und eine Woche dauert."),
        Shot(user: "wie spät ist es eigentlich in tokio",
             answer: "Wie spät ist es eigentlich in Tokio?"),
        Shot(user: "danke für die einladung ich komme gerne am samstag vorbei soll ich etwas zu essen mitbringen",
             answer: "Danke für die Einladung. Ich komme gerne am Samstag vorbei. Soll ich etwas zu essen mitbringen?"),
    ]

    private static let englishOrder: [Shot] = [
        Shot(user: "i documented the design in kon fluence last night", terms: ["Confluence"],
             answer: "I documented the design in Confluence last night."),
        Shot(user: "ich glaube daß er recht hat aber ich muß noch darüber nachdenken bevor ich zusage",
             answer: "Ich glaube, dass er recht hat, aber ich muss noch darüber nachdenken, bevor ich zusage."),
        Shot(user: "the flight leaves at six oh five and the ticket was four hundred and eighty seven dollars",
             answer: "The flight leaves at 6:05 and the ticket was $487."),
        Shot(user: "we need thirty seven chairs by the twenty ninth of november",
             answer: "We need 37 chairs by the 29th of November."),
        Shot(user: "the project has eighteen thousand lines of code and runs in about two point five seconds",
             answer: "The project has 18,000 lines of code and runs in about 2.5 seconds."),
        Shot(user: "the repair costs three hundred and sixty dollars and takes about a week",
             answer: "The repair costs $360 and takes about a week."),
        Shot(user: "ask jon from the sails team whether open ai has released the new model",
             answer: "Ask Jon from the sales team whether OpenAI has released the new model."),
        Shot(user: "what is the capital of australia",
             answer: "What is the capital of Australia?"),
        Shot(user: "thanks for the update i will review the document on wednesday and send you my comments",
             answer: "Thanks for the update. I will review the document on Wednesday and send you my comments."),
        Shot(user: "we moved the launch to the twelfth of october because the testers found two bugs",
             answer: "We moved the launch to the 12th of October because the testers found two bugs."),
        Shot(user: "i will call you back at five forty five tomorrow morning",
             answer: "I will call you back at 5:45 tomorrow morning."),
    ]
}
