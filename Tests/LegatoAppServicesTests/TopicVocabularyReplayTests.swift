import Foundation
import LegatoAgent
import LegatoCore
import LegatoSoniox
import LegatoVocabulary
import Testing
@testable import LegatoAppServices

/// Synthetic, independently labelled work sessions. Only the field and *preceding* takes exist at recognition start.
private struct TopicWorkload {
    let name: String
    let business: [String]
    let science: [String]
    let olderWork: [String]
    let durable: String
    let pin: String
    let takes: [Take]

    struct Take {
        enum Stage { case business, science, returning }
        let stage: Stage
        let field: String
        let spoken: String
        let target: String
        init(_ stage: Stage, _ field: String, _ spoken: String, _ target: String) {
            self.stage = stage
            self.field = field
            self.spoken = spoken
            self.target = target
        }
    }

    static let development = TopicWorkload(
        name: "development",
        business: "Nordkai Meridian Zollwert Intermodal Rollgeld Freightline Osthafen Wellenholm Hafenlotse Seefracht Balticline Brückenwert LogPort Elbtrasse HubWest Nordlager Tidenplan Lademarke Fleetbase Mainkai".components(separatedBy: " "),
        science: "Rubidium Cryostat Iontrap Doppler Zeeman Raman Fermion Boson Isobar Tokamak Neutrino Hadron Spinor Magneton Exciton Helicity Rydberg Nanofluid Plasmajet Coulomb".components(separatedBy: " "),
        olderWork: "Obsidian Dolomit Porphyr Baryt Granat Aquamarin Citrin Rauchquarz Graphit Achat Diorit Magnesit Onyx Pyrit Kalzit Topas Serpentin Basalt Kyanit Azurit".components(separatedBy: " "),
        durable: "Badhri", pin: "Kemas",
        takes: [
            .init(.business, "Nordkai dispatch", "Nordkai asked about the shipping schedule.", "Nordkai"),
            .init(.business, "", "Nordkai needs the Meridian invoice.", "Nordkai"),
            .init(.business, "", "Zollwert und Seefracht sind bestätigt.", "Zollwert"),
            .init(.science, "", "Move the Rubidium sample to the Cryostat.", "Rubidium"),
            .init(.science, "", "Rubidium shows a clear Zeeman shift.", "Rubidium"),
            .init(.science, "Cryostat: Messwerte", "Die Messung am Cryostat ist fertig.", "Cryostat"),
            .init(.returning, "Cryostat: Messwerte", "Nordkai needs the signed customs form.", "Nordkai"),
            .init(.returning, "", "Nordkai is waiting for Meridian.", "Nordkai"),
            .init(.returning, "Meridian", "Meridian confirmed the berth.", "Meridian")
        ])

    static let heldOut = TopicWorkload(
        name: "held-out",
        business: "Varento Isarwerk Asperia Mainbogen Lohnart Teralis Werkvertrag Alpenwert Borealis Fälligkeit Kiruna Projektzeit Wiesenhof Renova Veridian Quorina Velora Seebogen Kaltmiete Ulmwerk".components(separatedBy: " "),
        science: "Lysimeter Saprolit Porosität Regolith Brunisol Aquitard Perkolat Eutrophie Moräne Karstzone Rotlehm Monzonit Frostkeil Rhizosphäre Kryosol Löss Auenlehm Hydrolase Tektit Sedimentkern".components(separatedBy: " "),
        olderWork: "Spielfuge Diskant Bariton Allegro Arpeggio Fermate Cantabile Glissando Bordun Koloratur Portato Cembalo Stretto Rubato Ostinato Crescendo Zimbel Sonatine Andante Tenuto".components(separatedBy: " "),
        durable: "Sofiya", pin: "Neroli",
        takes: [
            .init(.business, "", "Varento will send a quote.", "Varento"),
            .init(.business, "Angebot von Isarwerk", "Isarwerk hat Varento beauftragt.", "Isarwerk"),
            .init(.business, "", "The Asperia contract needs a signature.", "Asperia"),
            .init(.science, "Angebot von Isarwerk", "Das Lysimeter ist jetzt eingebaut.", "Lysimeter"),
            .init(.science, "", "Check the Lysimeter before coring.", "Lysimeter"),
            .init(.science, "", "Das Profil zeigt Saprolit unter dem Regolith.", "Saprolit"),
            .init(.science, "Notizen zum Saprolit", "Saprolit depth varies across this plot.", "Saprolit"),
            .init(.returning, "", "Varento hat die Abrechnung geschickt.", "Varento"),
            .init(.returning, "Isarwerk und Varento", "Isarwerk can invoice Varento.", "Varento"),
            .init(.returning, "", "Mainbogen braucht die Unterschrift.", "Mainbogen")
        ])

    func entries(asOf now: Date) -> [VocabularyEntry] {
        var entries: [VocabularyEntry] = []
        for terms in [business, science, olderWork] {
            for (i, term) in terms.enumerated() {
                // The same spread of evidence in every domain; some terms straddle the request cap.
                entries.append(VocabularyEntry(text: term, source: .history, score: Double(3 + i % 7),
                    lastSeen: now.addingTimeInterval(-Double(i % 4 + 1) * 86_400)))
            }
        }
        entries.append(VocabularyEntry(text: durable, source: .history, score: 24, lastSeen: now))
        entries.append(VocabularyEntry(text: pin, source: .manual, lastSeen: now, pinned: true))
        return entries
    }
}

private struct TopicReplayScore {
    var wrongTopicSlots = 0
    var targetPresent = 0
    var durablePresent = 0
    var pinPresent = 0
    var scienceEntry: Int?
    var businessRecovery: Int?

    mutating func observe(_ hints: [String], during take: TopicWorkload.Take, in workload: TopicWorkload, stageOffset: Int) {
        let relevant = Set((take.stage == .science ? workload.science : workload.business) + [workload.pin, workload.durable])
        wrongTopicSlots += hints.filter { !relevant.contains($0) }.count
        if hints.contains(take.target) { targetPresent += 1 }
        if hints.contains(workload.durable) { durablePresent += 1 }
        if hints.contains(workload.pin) { pinPresent += 1 }
        if take.stage == .science, scienceEntry == nil, hints.contains(workload.science[0]) { scienceEntry = stageOffset }
        if take.stage == .returning, businessRecovery == nil, hints.contains(workload.business[0]) { businessRecovery = stageOffset }
    }
}

@Suite struct TopicVocabularyReplayTests {
    @Test func chronologicalRequestComparison() async throws {
        for workload in [TopicWorkload.development, .heldOut] {
            let baseline = try await replay(workload, contextual: false)
            let candidate = try await replay(workload, contextual: true)
            #expect(candidate.targetPresent >= baseline.targetPresent)
            let nextScience = candidate.scienceEntry ?? Int.max
            let earlierScience = baseline.scienceEntry ?? Int.max
            #expect(nextScience < earlierScience || candidate.wrongTopicSlots < baseline.wrongTopicSlots)
        }
    }

    private func replay(_ workload: TopicWorkload, contextual: Bool) async throws -> TopicReplayScore {
        let ordinary = Set(workload.takes.flatMap { VocabularyLearner.cueWords(in: $0.spoken) })
            .subtracting(VocabularyLearner.cueWords(in: (workload.business + workload.science).joined(separator: " ")))
        let rig = VocabularyRig(known: ordinary)
        defer { rig.cleanUp() }
        // Whole seconds give both histories the same serialized timestamp width for the storage comparison.
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        try await rig.service.store.update { $0.entries = workload.entries(asOf: now) }
        let root = rig.url.deletingLastPathComponent()
        let historyURL = root.appending(path: "history.jsonl")
        let storage = JSONLHistoryStore(fileURL: historyURL)
        let benchmark = ProcessInfo.processInfo.environment["LEGATO_VOCAB_BENCHMARK"] == "1"
        if benchmark {
            for _ in 0..<500 {
                try await storage.append(DictationEntry(date: now.addingTimeInterval(-86_400), text: "Old archived take",
                                                       localeIdentifier: "en_DE", engineID: "soniox", duration: 2))
            }
        }
        let history = LearningHistoryStore(storage, vocabulary: rig.service)
        await history.warmTopicContext()
        let recentURL = root.appending(path: "recent-takes.json")
        let recent = RecentTakesStore(fileURL: recentURL)
        let request = RequestVocabulary(fileURL: rig.url)
        var score = TopicReplayScore()
        var stage: TopicWorkload.Take.Stage?
        var stageOffset = 0
        for (requestNumber, take) in workload.takes.enumerated() {
            if take.stage != stage { stage = take.stage; stageOffset = 0 }
            let wire = try await wireRequest(request, recent: recent, history: history, field: take.field, contextual: contextual)
            let hints = wire.terms
            #expect(hints.count == 50)
            score.observe(hints, during: take, in: workload, stageOffset: stageOffset)
            var entry = DictationEntry(date: now.addingTimeInterval(Double(requestNumber) - 300), text: take.spoken,
                                       localeIdentifier: "en_DE", engineID: "soniox", duration: 3)
            // The fixture repeats Soniox's receipt contract using the terms and background actually serialized.
            let heard = VocabularyLearner.cueWords(in: entry.text)
            entry.recognitionHints = heard.intersection(VocabularyLearner.cueWords(in: wire.cues)).sorted()
            try await history.upsert(entry)
            await rig.service.waitForLearning()
            recent.record(raw: take.spoken, cleaned: take.spoken, wasCleaned: false, id: entry.id)
            stageOffset += 1
        }

        let n = workload.takes.count
        #expect(score.pinPresent == n)
        #expect(score.durablePresent == n)
        let label = "Topic replay \(workload.name) contextual=\(contextual)"
        let science = score.scienceEntry.map(String.init) ?? "absent"
        let recovery = score.businessRecovery.map(String.init) ?? "absent"
        print("\(label) requests=\(n) wrongSlots=\(score.wrongTopicSlots) target=\(score.targetPresent) scienceDelay=\(science) returnDelay=\(recovery) durable=\(score.durablePresent) pin=\(score.pinPresent)")
        guard benchmark else { return score }

        var diskBytes = 0
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        while let url = files?.nextObject() as? URL {
            if ["json", "jsonl"].contains(url.pathExtension) {
                diskBytes += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            }
        }
        let freshRequest = RequestVocabulary(fileURL: rig.url)
        let freshTakes = RecentTakesStore(fileURL: recentURL)
        let gate = AsyncStream<Void>.makeStream()
        let coldHistory = LearningHistoryStore(PausedHistoryRead(base: storage, release: gate.stream), vocabulary: rig.service)
        let clock = ContinuousClock()
        func readMilliseconds() async throws -> Double {
            let duration = try await clock.measure {
                _ = try await wireRequest(freshRequest, recent: freshTakes, history: coldHistory,
                                          field: workload.business[0], contextual: contextual)
            }
            return duration.milliseconds
        }
        // Freeze the launch-time disk read so the cold request deterministically uses its fallback.
        let cold = try await readMilliseconds()
        let hydration = await clock.measure {
            gate.continuation.finish()
            await coldHistory.warmTopicContext()
        }
        var samples: [Double] = []
        for _ in 0..<11 { samples.append(try await readMilliseconds()) }
        let warmMedian = samples.sorted()[samples.count / 2]
        print("\(label) jsonBytes=\(diskBytes) coldMs=\(cold) warmMedianMs=\(warmMedian) hydrationMs=\(hydration.milliseconds)")
        return score
    }

    private func wireRequest(_ request: RequestVocabulary, recent: RecentTakesStore, history: LearningHistoryStore,
                             field: String, contextual: Bool) async throws -> (terms: [String], cues: String) {
        let terms: [String]
        if contextual {
            terms = await request.sonioxTerms(contextFor: { history.topicContext(textBeforeCursor: field, since: $0) })
        } else {
            terms = await request.sonioxTerms()
        }
        let message = try SonioxConfig(mode: "Dictation", terms: terms).message(backgroundText: recent.backgroundText())
        let json = try #require(JSONSerialization.jsonObject(with: message) as? [String: Any])
        let wire = try #require(json["context"] as? [String: Any])
        let selected = try #require(wire["terms"] as? [String])
        let general = try #require(wire["general"] as? [[String: String]])
        let cueText = (selected + general.compactMap { $0["value"] } + [wire["text"] as? String ?? ""]).joined(separator: " ")
        return (selected, cueText)
    }
}

/// Only the one launch-time history read is suspended, letting the first-request measurement be repeatable.
private struct PausedHistoryRead: HistoryStore {
    let base: JSONLHistoryStore
    let release: AsyncStream<Void>
    func recent(limit: Int) async throws -> [DictationEntry] {
        for await _ in release { break }
        return try await base.recent(limit: limit)
    }
    func append(_ entry: DictationEntry) async throws { try await base.append(entry) }
    func delete(id: UUID) async throws { try await base.delete(id: id) }
}

private extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
