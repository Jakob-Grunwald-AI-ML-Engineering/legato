import Foundation

// Spike #95 fixture: the continuous-agent stream and its annotated mistakes, in stream order. Each passage has
// tags (register, length, language, content, speaking style); each sentence the raw dictation (`text`, as the
// ASR wrote it) and the clean `reference`. Each mistake names the `wrong` span that must disappear and the
// `fixes` of which one must appear (none: removing the span is enough), matched case-sensitively on word
// boundaries; `type` is the error type. `local` mistakes (l) count from the chunk that completes the wrong span,
// `sentence` rewrites (s) from the chunk that ends the sentence.
//
// Sources: P01–P12 are spikes/keyboard-corrections/Fixtures/patches.json (old → new; P04 is a user edit, not a
// mistake, and is left out); WA is Jakob's raw WhatsApp transcript; the rest is written for this probe with
// planted ASR-style errors. Names, addresses and domains are invented (example.com).

extension ProbeCorpus {
    private static func l(_ type: String, _ wrong: String, _ fixes: String...) -> ProbeMistake {
        ProbeMistake(wrong: wrong, fixes: fixes, kind: .local, type: type)
    }
    private static func s(_ type: String, _ wrong: String, _ fixes: String...) -> ProbeMistake {
        ProbeMistake(wrong: wrong, fixes: fixes, kind: .sentence, type: type)
    }
    private typealias Line = (id: String, text: String, reference: String, mistakes: [ProbeMistake])
    private static func passage(_ id: String, _ tags: [String], _ lines: [Line]) -> [ProbeSentence] {
        lines.map { ProbeSentence(id: $0.id, passage: id, tags: tags, text: $0.text, reference: $0.reference, mistakes: $0.mistakes) }
    }

    public static let sentences: [ProbeSentence] = [
        passage("fixtures", ["register:note", "length:oneliner", "lang:en"], [
            ("P01", "Send teh report while the meeting continues with no change to the remaining facts.",
             "Send the report while the meeting continues with no change to the remaining facts.", [l("spelling", "teh", "the")]),
            ("P02", "Send report while the meeting continues with no change to the remaining facts.",
             "Send the report while the meeting continues with no change to the remaining facts.", [l("missing-word", "Send report", "Send the report")]),
            ("P03", "Send the the report while the meeting continues with no change to the remaining facts.",
             "Send the report while the meeting continues with no change to the remaining facts.", [l("repetition", "the the", "the")]),
            ("P05", "Café and café remain.", "Café and café remain.", []),
            ("P06", "Keep 👩🏽‍💻 teh 🇩🇪 flag and 👨‍👩‍👧‍👦.", "Keep 👩🏽‍💻 the 🇩🇪 flag and 👨‍👩‍👧‍👦.", [l("spelling", "teh", "the")]),
            ("P07", "send teh report.", "Send the report.", [l("spelling", "teh", "the")]),
            ("P08", "hello wor.", "Hello world.", [l("artefact", "wor", "world")]),
            ("P09", "send teh report.", "Send the report.", [l("spelling", "teh", "the")]),
            ("P10", "send teh report.", "Send the report.", [l("spelling", "teh", "the")]),
            ("P11", "hello world.", "Hello world.", [l("casing", "hello", "Hello")]),
            ("P12", "send teh report suffix.", "Send the report suffix.", [l("spelling", "teh", "the")]),
        ]),
        passage("whatsapp", ["register:chat", "length:monologue", "lang:en", "style:hesitant"], [
            ("T1", "Hello, I'm testing this out now, is with with obvious spelling mistakes, such as tea.",
             "Hello, I'm testing this out now, with obvious spelling mistakes, such as tea.", [l("repetition", "with with", "with")]),
            ("T2", "Um, something.", "Something.", [l("filler", "Um")]),
            ("T3", "Hmm.", "", [l("filler", "Hmm")]),
            ("T4", "#um, I don't think it was doing like a proper replace finally replaced.",
             "I don't think it was doing a proper replace; finally it replaced.",
             [l("artefact", "#um"), s("rewrite", "like a proper replace finally replaced")]),
            ("T5", "Edit.", "Edit.", []),
            ("T6", "#ah.", "", [l("artefact", "#ah")]),
            ("T7", "I don't know.", "I don't know.", []),
            ("T8", "I don't think it's working.", "I don't think it's working.", []),
            ("T9", "#HM, maybe some things are working.", "Maybe some things are working.", [l("artefact", "#HM")]),
            ("T10", "#um, I like to go to Te Beach.", "I'd like to go to the beach.",
             [l("artefact", "#um"), l("wrong-word", "Te Beach", "the beach")]),
        ]),
        passage("email-en", ["register:email", "length:monologue", "lang:en", "content:names", "content:numbers", "content:email"], [
            ("E1", "Hi Sarah, #um, I wanted to check weather you got my message from Tuesday.",
             "Hi Sarah, I wanted to check whether you got my message from Tuesday.", [l("artefact", "#um"), l("homophone", "weather", "whether")]),
            ("E2", "The meeting is at three thirty PM in berlin with Dr. Weber, and I will definately be their.",
             "The meeting is at 3:30 PM in Berlin with Dr. Weber, and I will definitely be there.",
             [l("number", "three thirty PM", "3:30 PM", "3:30 p.m.", "3.30 PM", "3:30pm"), l("casing", "berlin", "Berlin"),
              l("spelling", "definately", "definitely"), l("homophone", "be their", "be there")]),
            ("E3", "Please send the seperate contracts to anna at example dot com by friday.",
             "Please send the separate contracts to anna@example.com by Friday.",
             [l("spelling", "seperate", "separate"), l("email", "anna at example dot com", "anna@example.com"), l("casing", "friday", "Friday")]),
        ]),
        passage("note", ["register:note", "length:short", "lang:en", "content:list"], [
            ("N1", "Note to self buy rope shackles and a new peace of canvas.", "Note to self: buy rope, shackles and a new piece of canvas.",
             [l("punctuation", "self buy", "self: buy", "self, buy", "Buy"), l("homophone", "peace of", "piece of")]),
            ("N2", "Number one call the rigger number two check the bilge pump number three order fuel filters.",
             "1. Call the rigger. 2. Check the bilge pump. 3. Order fuel filters.", [s("list", "rigger number two check")]),
        ]),
        passage("technical", ["register:technical", "length:short", "lang:en", "content:product-names", "content:numbers"], [
            ("K1", "The build fails because x code can't find the swift package for m l x.",
             "The build fails because Xcode can't find the Swift package for MLX.",
             [l("boundary", "x code", "Xcode"), l("boundary", "m l x", "MLX")]),
            ("K2", "Delete derived data and rebuild, then run the tests again.", "Delete DerivedData and rebuild, then run the tests again.",
             [l("casing", "derived data", "DerivedData", "Derived Data")]),
            ("K3", "The API returns a four oh four when the user I D is missing.", "The API returns a 404 when the user ID is missing.",
             [l("number", "four oh four", "404"), l("boundary", "I D", "ID")]),
        ]),
        passage("explanatory", ["register:explanatory", "length:monologue", "lang:en", "content:numbers"], [
            ("X1", "So basically what I'm trying to say is that the forecast was wrong again, which is a problem because we planned to leave at for in the morning and the harbour master said the swell would be to high for a boat our size.",
             "The forecast was wrong again, which is a problem: we planned to leave at four in the morning, and the harbour master said the swell would be too high for a boat our size.",
             [s("rewrite", "So basically what I'm trying to say is that"), l("homophone", "at for", "at four", "at 4"),
              l("homophone", "to high", "too high")]),
            ("X2", "The reason why is because the low moved further north than expected, and that changes everything for the crossing.",
             "The low moved further north than expected, and that changes everything for the crossing.", [s("rewrite", "The reason why is because")]),
        ]),
        passage("self-correction", ["register:chat", "length:short", "lang:en", "style:self-correction", "content:numbers"], [
            ("S1", "I want to, no wait, I need to cancel the order for the new sails.", "I need to cancel the order for the new sails.",
             [s("self-correction", "I want to, no wait,", "need to cancel")]),
            ("S2", "Let's meet at the peer at seven, I mean eight, and bring you're jacket.", "Let's meet at the pier at eight and bring your jacket.",
             [l("homophone", "peer", "pier"), s("self-correction", "seven, I mean eight", "eight", "8"), l("homophone", "you're jacket", "your jacket")]),
        ]),
        passage("run-on", ["register:chat", "length:monologue", "lang:en", "style:run-on"], [
            ("R1", "ok so I'm at the marina now the boat is fine but the battery is dead again can you call the electrician and ask if he can come tomorrow morning",
             "OK, so I'm at the marina now. The boat is fine, but the battery is dead again. Can you call the electrician and ask if he can come tomorrow morning?",
             [s("punctuation", "marina now the boat"), s("punctuation", "dead again can you")]),
        ]),
        passage("hesitant", ["register:chat", "length:monologue", "lang:en", "style:hesitant"], [
            ("H1", "So, uh, the engine was, um, making a weird noise and and I didn't, I didn't know what to do.",
             "So the engine was making a weird noise and I didn't know what to do.",
             [l("filler", "uh"), l("filler", "um"), l("repetition", "and and", "and"), l("repetition", "I didn't, I didn't", "I didn't")]),
            ("H2", "It was like, you know, really loud and I was worried we'd loose the mast.", "It was really loud and I was worried we'd lose the mast.",
             [l("filler", "you know"), l("homophone", "loose", "lose")]),
        ]),
        passage("boundaries", ["register:chat", "length:short", "lang:en"], [
            ("B1", "We need to take the engine a part before we can fix it, and every one says it's worth it.",
             "We need to take the engine apart before we can fix it, and everyone says it's worth it.",
             [l("boundary", "a part", "apart"), l("boundary", "every one says", "everyone says")]),
            ("B2", "Its going to be windy to, so lets wait.", "It's going to be windy too, so let's wait.",
             [l("homophone", "Its", "It's", "It is"), l("homophone", "windy to", "windy too"), l("homophone", "lets", "let's", "let us")]),
        ]),
        passage("chat-de", ["register:chat", "length:short", "lang:de"], [
            ("D1", "Hallo Jakob, ich komme morgen vorbei, dass heißt wir können zusammen frühstücken.",
             "Hallo Jakob, ich komme morgen vorbei, das heißt, wir können zusammen frühstücken.", [l("homophone", "dass heißt", "das heißt")]),
            ("D2", "Kannst du bitte die Seile mit bringen und vergiss nicht das Ladegerät.",
             "Kannst du bitte die Seile mitbringen, und vergiss nicht das Ladegerät.", [l("boundary", "mit bringen", "mitbringen")]),
            ("D3", "#äh, wo seit ihr gerade, im Hafen oder schon auf See?", "Wo seid ihr gerade, im Hafen oder schon auf See?",
             [l("artefact", "#äh"), l("homophone", "seit ihr", "seid ihr")]),
            ("D4", "Das Wetter soll am wochenende besser werden.", "Das Wetter soll am Wochenende besser werden.",
             [l("casing", "wochenende", "Wochenende")]),
        ]),
        passage("email-de", ["register:email", "length:short", "lang:de", "content:names", "content:dates"], [
            ("M1", "Sehr geehrte Frau Müller, anbei sende ich ihnen die Unterlagen für den Termin am zweiten März.",
             "Sehr geehrte Frau Müller, anbei sende ich Ihnen die Unterlagen für den Termin am 2. März.",
             [l("casing", "ihnen", "Ihnen"), l("number", "zweiten März", "2. März")]),
        ]),
        passage("mixed", ["register:chat", "length:short", "lang:mixed", "content:product-names"], [
            ("Y1", "Hey, kannst du mir den Link zum Google Doc schicken, I need it for the meeting tomorow.",
             "Hey, kannst du mir den Link zum Google Doc schicken? I need it for the meeting tomorrow.", [l("spelling", "tomorow", "tomorrow")]),
            ("Y2", "Das deployment ist gescheitert, weil der API key abgelaufen ist.", "Das Deployment ist gescheitert, weil der API-Key abgelaufen ist.",
             [l("casing", "deployment", "Deployment")]),
        ]),
        passage("urls", ["register:technical", "length:oneliner", "lang:en", "content:urls", "content:numbers"], [
            ("U1", "The docs are at w w w dot example dot com slash docs, see section two point three.",
             "The docs are at www.example.com/docs, see section 2.3.",
             [l("url", "w w w dot example dot com slash docs", "www.example.com/docs", "example.com/docs"),
              l("number", "section two point three", "section 2.3")]),
        ]),
        passage("closing", ["register:chat", "length:oneliner", "lang:en"], [
            ("Z1", "Please book a table for four people on Friday at seven.", "Please book a table for four people on Friday at seven.", []),
            ("Z2", "Thanks again for you're help with the rigging.", "Thanks again for your help with the rigging.",
             [l("homophone", "you're help", "your help")]),
            ("Z3", "The new sails arrive next week and the rigger will fit them on Tuesday.",
             "The new sails arrive next week and the rigger will fit them on Tuesday.", []),
            ("Z4", "See you tomorow.", "See you tomorrow.", [l("spelling", "tomorow", "tomorrow")]),
        ]),
    ].flatMap { $0 }
}
