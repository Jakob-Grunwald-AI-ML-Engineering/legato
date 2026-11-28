import Foundation

/// One step of a guided voice recording: read a sentence aloud, or stay quiet.
public struct VoiceScriptStep: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case reading(String), quiet }
    public var kind: Kind
    /// Planned length: the estimated reading time of a sentence, or the exact length of a quiet pause.
    public var seconds: Double
    public init(kind: Kind, seconds: Double) { self.kind = kind; self.seconds = seconds }
    public var prompt: String? { if case .reading(let text) = kind { text } else { nil } }
    /// For a quiet pause its length. For a reading step, how long it runs before the sheet offers a hint; it still
    /// ends only when the reader stops speaking, or on Next sentence.
    public var maximumSeconds: Double { prompt == nil ? seconds : seconds * VoiceReadingScript.readingTolerance }
    /// The estimated time spent speaking a reading step: its estimate without the moment to start.
    public var speechSeconds: Double { max(1, seconds - VoiceReadingScript.startSeconds) }
}

/// What the user reads and when they stay quiet. The first setup reads about a minute in a quiet room; a setting
/// recording reads about 40 s, with two 10-second quiet pauses, so the quiet parts hold only the surroundings.
public struct VoiceReadingScript: Sendable, Equatable {
    public static let setupReadingSeconds = 60.0
    public static let settingReadingSeconds = 40.0
    public static let quietSeconds = 10.0
    /// A reading step still running at this multiple of its estimate shows a hint (it never ends on time alone).
    public static let readingTolerance = 1.6

    public var language: String
    public var steps: [VoiceScriptStep]
    /// Where the next setting recording starts in the prompt rotation.
    public var nextCursor: Int
    public var sentenceCount: Int { steps.filter { $0.prompt != nil }.count }
    public var plannedSeconds: Double { steps.reduce(0) { $0 + $1.seconds } }

    /// The moment a reader takes to start a sentence, part of its estimate.
    public static let startSeconds = 1.5

    /// About 2.4 words a second, plus a moment to start; never under four seconds.
    public static func readingSeconds(for sentence: String) -> Double {
        max(4, Double(sentence.split(whereSeparator: \.isWhitespace).count) / 2.4 + startSeconds)
    }

    /// Whether one more sentence of `seconds` brings the reading closer to `target` than stopping now.
    private static func fits(_ seconds: Double, after total: Double, target: Double) -> Bool {
        total == 0 || total + seconds / 2 <= target
    }

    public static func firstSetup(language: String) -> Self {
        let prompts = VoiceReadingPrompts.setup(language: language)
        var steps: [VoiceScriptStep] = [], total = 0.0
        for prompt in prompts {
            let seconds = readingSeconds(for: prompt)
            guard fits(seconds, after: total, target: setupReadingSeconds) else { break }
            total += seconds
            steps.append(.init(kind: .reading(prompt), seconds: seconds))
        }
        return Self(language: language, steps: steps, nextCursor: 0)
    }

    /// Sentences from the rotation pool, starting at `cursor`, for about 40 s of reading, in three blocks
    /// separated by the two quiet pauses. `nextCursor` is where the next recording starts, so successive recordings
    /// read different sentences until the pool comes round again. `sentences` fixes how many are read instead (a
    /// retry reads as many as the attempt before it, though other sentences).
    public static func setting(language: String, cursor: Int, sentences count: Int? = nil) -> Self {
        let pool = VoiceReadingPrompts.rotation(language: language)
        var sentences: [(String, Double)] = [], total = 0.0, index = max(0, cursor) % max(1, pool.count)
        while sentences.count < min(count ?? pool.count, pool.count) {
            let prompt = pool[index % pool.count], seconds = readingSeconds(for: prompt)
            guard count != nil || fits(seconds, after: total, target: settingReadingSeconds) else { break }
            index += 1; total += seconds
            sentences.append((prompt, seconds))
        }
        var steps: [VoiceScriptStep] = [], elapsed = 0.0, pauses = 0
        for (offset, (prompt, seconds)) in sentences.enumerated() {
            steps.append(.init(kind: .reading(prompt), seconds: seconds)); elapsed += seconds
            let isLast = offset == sentences.count - 1
            if !isLast && pauses < 2 && elapsed >= total * Double(pauses + 1) / 3 {
                steps.append(.init(kind: .quiet, seconds: quietSeconds)); pauses += 1
            }
        }
        while pauses < 2 { steps.append(.init(kind: .quiet, seconds: quietSeconds)); pauses += 1 }
        return Self(language: language, steps: steps, nextCursor: index % max(1, pool.count))
    }
}

/// Reading prompts written for Legato (no quoted text): everyday, varied sentences with a wide spread of sounds.
public enum VoiceReadingPrompts {
    /// How many sentences of each language the first setup draws from; the rest rotate through setting recordings.
    static let setupCount = 7

    /// `de` when the first preferred language is German, otherwise `en`.
    public static func language(preferred: [String] = Locale.preferredLanguages) -> String {
        (preferred.first ?? "en").lowercased().hasPrefix("de") ? "de" : "en"
    }
    public static func all(language: String) -> [String] { language == "de" ? german : english }
    static func setup(language: String) -> [String] { Array(all(language: language).prefix(setupCount)) }
    static func rotation(language: String) -> [String] { Array(all(language: language).dropFirst(setupCount)) }

    static let english = [
        "This morning I made a strong cup of coffee, opened the window, and listened to the birds arguing in the garden.",
        "If the weather holds on Thursday, we could take the bikes along the river and stop for lunch at the old mill.",
        "Please remind me to call the dentist, buy fresh bread, and send the invoice before the office closes at five.",
        "My neighbour just bought a bright yellow kayak, and now he wants everyone to join him on the lake this summer.",
        "A quiet street at dusk has its own music: footsteps, a distant dog, and somebody practising the violin upstairs.",
        "When I travel, I always pack too many books and forget the charger, so I end up reading by candlelight.",
        "Could you check whether the package arrived? It should be a small brown box with a blue label on the side.",
        "The recipe asks for two eggs, a pinch of salt, half a cup of sugar, and a generous spoonful of vanilla.",
        "Every Friday the market fills with the smell of roasted chestnuts, fresh herbs, and warm pretzels straight from the oven.",
        "I think the meeting went well, although we still need a clear plan for the budget and a realistic deadline.",
        "Our train was delayed by twenty minutes, so we bought sandwiches and watched the clouds drift over the hills.",
        "She tied the boat to the jetty, checked the ropes twice, and then walked slowly up the sandy path.",
        "Let's move the workshop to Wednesday afternoon and invite the new team, because they have fresh ideas to share.",
        "The children built a huge snowman with a carrot nose, pebble eyes, and a scarf borrowed from their grandfather.",
        "Before you leave, switch off the heating, water the plants, and leave the spare key with the neighbours.",
        "I'd like a table for four near the window, please, and could we see the dessert menu right away?",
        "Thunder rolled across the valley while we hurried home, laughing, with our shoes full of rainwater.",
        "The library downtown has a cozy reading room with leather chairs, tall shelves, and a very strict librarian.",
        "Remember that the flight leaves at seven fifteen, so we should be at the airport no later than half past five.",
        "My favourite part of the weekend is a long breakfast with jazz on the radio and nowhere to be.",
        "The engineer explained the new bridge design using a pencil sketch, three coffee cups, and a lot of patience.",
        "Honestly, I can never decide between the mountains and the sea, so this year we're doing both.",
        "Write down the address carefully: number twelve, second floor, the door with the green handle.",
        "A gentle breeze moved the curtains while the kettle whistled and the cat jumped onto the kitchen table.",
        "We measured the room twice, but the new sofa still didn't fit through the narrow hallway door.",
        "Thanks for your message yesterday; I'll have a closer look at the numbers and get back to you by Monday.",
        "The violinist tuned her instrument, closed her eyes, and played a melody that silenced the whole hall.",
        "Next spring I want to plant tomatoes, zucchini, sunflowers, and maybe a small apple tree by the fence.",
        "Somebody left a mysterious parcel on the doorstep, wrapped in newspaper and tied with bright red string.",
        "The museum offers free guided tours on Sundays, but you have to register online a week in advance.",
        "Pack warm socks, a waterproof jacket, and a flask of tea, because the forecast says it'll be freezing.",
        "Just a quick update: the printer works again, the shelves are sorted, and lunch is on the table.",
        "Through the fog we could barely see the lighthouse, but its slow, steady beam guided us home.",
        "Could we push the call to half past three? I'm still stuck in traffic on the motorway.",
        "Grandma's famous plum cake needs patience, a hot oven, and someone willing to wash all the bowls.",
        "The zoo's newest arrival is a shy baby giraffe who hides behind her mother whenever visitors wave.",
    ]

    static let german = [
        "Heute Morgen habe ich einen starken Kaffee gekocht, das Fenster geöffnet und den Vögeln im Garten zugehört.",
        "Wenn das Wetter am Donnerstag hält, könnten wir mit den Fahrrädern am Fluss entlang zur alten Mühle fahren.",
        "Erinnere mich bitte daran, den Zahnarzt anzurufen, frisches Brot zu kaufen und die Rechnung vor fünf Uhr zu schicken.",
        "Mein Nachbar hat sich ein knallgelbes Kajak gekauft und will diesen Sommer jeden mit auf den See nehmen.",
        "Eine ruhige Straße in der Abenddämmerung hat ihre eigene Musik: Schritte, ein ferner Hund und Geigenübungen im dritten Stock.",
        "Wenn ich verreise, packe ich immer zu viele Bücher ein und vergesse das Ladekabel, also lese ich bei Kerzenlicht.",
        "Kannst du nachsehen, ob das Paket angekommen ist? Es ist ein kleiner brauner Karton mit einem blauen Aufkleber.",
        "Für das Rezept braucht man zwei Eier, eine Prise Salz, eine halbe Tasse Zucker und einen großzügigen Löffel Vanille.",
        "Jeden Freitag duftet der Markt nach gerösteten Maronen, frischen Kräutern und warmen Brezeln direkt aus dem Ofen.",
        "Ich glaube, die Besprechung lief gut, aber wir brauchen noch einen klaren Plan für das Budget und einen realistischen Termin.",
        "Unser Zug hatte zwanzig Minuten Verspätung, also haben wir Brötchen gekauft und den Wolken über den Hügeln zugesehen.",
        "Sie machte das Boot am Steg fest, prüfte die Leinen zweimal und ging dann langsam den sandigen Weg hinauf.",
        "Lass uns den Workshop auf Mittwochnachmittag verschieben und das neue Team einladen, denn es hat frische Ideen.",
        "Die Kinder bauten einen riesigen Schneemann mit Karottennase, Kieselsteinaugen und einem Schal vom Großvater.",
        "Bevor du gehst, dreh bitte die Heizung ab, gieß die Pflanzen und gib den Ersatzschlüssel bei den Nachbarn ab.",
        "Ich hätte gern einen Tisch für vier Personen am Fenster, und könnten wir gleich die Dessertkarte sehen?",
        "Der Donner grollte durch das Tal, während wir lachend nach Hause liefen, die Schuhe voller Regenwasser.",
        "Die Bibliothek in der Innenstadt hat einen gemütlichen Lesesaal mit Ledersesseln, hohen Regalen und einer strengen Bibliothekarin.",
        "Denk daran, dass der Flug um Viertel nach sieben geht, also sollten wir spätestens um halb sechs am Flughafen sein.",
        "Am Wochenende mag ich am liebsten ein langes Frühstück mit Jazz im Radio und ohne jeden Termin.",
        "Der Ingenieur erklärte den neuen Brückenentwurf mit einer Bleistiftskizze, drei Kaffeetassen und sehr viel Geduld.",
        "Ehrlich gesagt kann ich mich nie zwischen Bergen und Meer entscheiden, deshalb machen wir dieses Jahr beides.",
        "Schreib dir die Adresse genau auf: Hausnummer zwölf, zweiter Stock, die Tür mit dem grünen Griff.",
        "Eine sanfte Brise bewegte die Vorhänge, der Wasserkessel pfiff und die Katze sprang auf den Küchentisch.",
        "Wir haben das Zimmer zweimal ausgemessen, aber das neue Sofa passte trotzdem nicht durch die schmale Flurtür.",
        "Danke für deine Nachricht von gestern; ich schaue mir die Zahlen genauer an und melde mich bis Montag.",
        "Die Geigerin stimmte ihr Instrument, schloss die Augen und spielte eine Melodie, die den ganzen Saal verstummen ließ.",
        "Im nächsten Frühling möchte ich Tomaten, Zucchini, Sonnenblumen und vielleicht einen kleinen Apfelbaum am Zaun pflanzen.",
        "Jemand hat ein rätselhaftes Päckchen vor die Tür gelegt, in Zeitungspapier gewickelt und mit roter Schnur verschnürt.",
        "Das Museum bietet sonntags kostenlose Führungen an, aber man muss sich eine Woche vorher online anmelden.",
        "Pack warme Socken, eine Regenjacke und eine Thermoskanne Tee ein, denn laut Vorhersage wird es eiskalt.",
        "Kurzes Update: Der Drucker funktioniert wieder, die Regale sind sortiert und das Mittagessen steht auf dem Tisch.",
        "Durch den Nebel sahen wir den Leuchtturm kaum, aber sein langsamer, gleichmäßiger Strahl führte uns nach Hause.",
        "Können wir das Gespräch auf halb vier verschieben? Ich stecke noch auf der Autobahn im Stau.",
        "Omas berühmter Zwetschgenkuchen braucht Geduld, einen heißen Ofen und jemanden, der hinterher alle Schüsseln spült.",
        "Der neueste Bewohner des Zoos ist eine schüchterne kleine Giraffe, die sich versteckt, sobald Besucher winken.",
    ]
}
