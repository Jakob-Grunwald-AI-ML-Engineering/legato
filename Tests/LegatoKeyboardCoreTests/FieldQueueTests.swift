import Testing
@testable import LegatoKeyboardCore

@Suite struct FieldQueueTests {
    @Test func liveTextAppendsAtTheCursorAndAcks() {
        var rig = QueueRig(FakeField("Note: "))
        rig.queue.enqueue(snap(1, "hello world"))
        let drained = rig.drain(); #expect(drained)
        #expect(rig.field.string == "Note: hello world")
        #expect(rig.events.contains { $0.event == .liveApplied(runID: "r", version: 1, complete: false) })
    }

    @Test func aSonioxFlipNearTheCaretIsDeletedAndRetypedAtTheCaret() {
        var rig = QueueRig(FakeField(""))
        rig.queue.enqueue(snap(1, "I think the plan is fine"))
        rig.drain()
        let before = rig.sent.count
        rig.queue.enqueue(snap(2, "I think the plant is fine"))
        rig.drain()
        let ops = rig.sent[before...].map(\.op)
        #expect(rig.field.string == "I think the plant is fine")
        // No jump: the characters from the change to the caret go, and the revised rest is typed again.
        #expect(ops == [.deleteBackward(8), .insert("t is fine")])
    }

    /// A revision further back than `nearChars` waits for the stop while new words go on at the caret.
    @Test func aFarRevisionWaitsForTheStopsSwap() {
        var rig = QueueRig(FakeField(""))
        let tail = " and then we went on talking about the weather and the boat for a long while"
        rig.queue.enqueue(snap(1, "I think the plan is fine" + tail))
        rig.drain()
        let before = rig.sent.count
        rig.queue.enqueue(snap(2, "I think the plant is fine" + tail + " today"))
        rig.drain()
        #expect(rig.field.string == "I think the plan is fine" + tail + " today")
        #expect(rig.sent[before...].map(\.op) == [.insert(" today")])
        #expect(!rig.sent.contains { if case .move = $0.op { true } else { false } })
        rig.queue.enqueue(snap(3, "I think the plant is fine" + tail + " today.", complete: true))
        rig.drain()
        // The take is longer than the field's window: the swap reads further back first (moves), then swaps it whole.
        #expect(rig.field.string == "I think the plant is fine" + tail + " today.")
        #expect(rig.drops.isEmpty)
    }

    @Test func aFlipGoesInOneChunk() {
        var rig = QueueRig(FakeField(""), config: .init())
        rig.queue.enqueue(snap(1, "a cat sat"))
        rig.drain()
        let before = rig.sent.count
        rig.queue.enqueue(snap(2, "a black cat sat"))
        rig.drain()
        // A revision near the caret: one delete run back to the change, one insert from there.
        let inserts = rig.sent[before...].compactMap { if case .insert(let s) = $0.op { s } else { nil } }
        #expect(inserts == ["black cat sat"])
        #expect(rig.field.string == "a black cat sat")
    }

    /// The user's key waits only for the chunk on its way, even behind a lagging host.
    @Test func aUserKeyDuringABusyQueueLandsWithinTheBoundAtTheUsersCursor() {
        var field = FakeField("")
        field.lagTicks = 2
        var rig = QueueRig(field, config: .init())
        rig.queue.enqueue(snap(1, String(repeating: "dictated words keep coming ", count: 6)))
        rig.run(ms: 600)
        let typedSoFar = rig.field.string
        rig.queue.enqueue(.insert("X"))
        let asked = rig.clockMs
        rig.run(ms: 400)
        let keyAt = rig.sent.first { if $0.ms > asked, case .insert(let s) = $0.op { s.hasSuffix("X") } else { false } }?.ms
        #expect(keyAt != nil)
        #expect((keyAt ?? .infinity) - asked <= FieldQueue.checkDeadlineMs + 2 * rig.tickMs)
        rig.drain()
        // The key closed the region at its place; the run went on after it.
        let text = rig.field.string
        let key = text.firstIndex(of: "X")!
        #expect(text[..<key].count >= typedSoFar.count)
        #expect(!text.contains("XX"))
    }

    @Test func aUserCursorMoveRebasesAPendingEdit() {
        var rig = QueueRig(FakeField("I saw teh cat. "))
        rig.queue.enqueue(.move(-5))
        rig.queue.enqueue(FieldQueue.Edit(id: "magic", kind: .magic, before: "I saw teh cat. ", after: "",
                                          target: "I saw the cat. ", cursorAtEnd: false))
        rig.drain()
        #expect(rig.field.string == "I saw the cat. ")
        #expect(rig.applied == ["magic"])
        // The user's caret stays where they put it (before "cat").
        #expect(rig.field.caret == 10)
    }

    @Test func aRevisionAtTheCaretNeverMovesTheCaret() {
        var field = FakeField("")
        field.lagTicks = 1
        var rig = QueueRig(field)
        rig.queue.enqueue(snap(1, "one two three four five"))
        rig.drain()
        rig.queue.enqueue(snap(2, "one too three for five"))
        rig.drain()
        rig.queue.enqueue(FieldQueue.Edit(id: "typed", kind: .typist, target: " six", atCursor: true))
        rig.drain()
        #expect(rig.field.string == "one too three for five six")
        #expect(!rig.sent.contains { if case .move = $0.op { true } else { false } })
    }

    @Test func anUnplaceableEditDropsWithAnEventAndEverythingElseContinues() {
        var rig = QueueRig(FakeField("Hello there"))
        rig.queue.enqueue(FieldQueue.Edit(id: "gone", kind: .magic, before: "Text that is not here", after: "", target: "Other"))
        rig.queue.enqueue(.insert("!"))
        rig.queue.enqueue(snap(1, "and more"))
        rig.drain()
        #expect(rig.drops.map(\.id) == ["gone"])
        #expect(rig.drops.first?.reason == .changed)
        #expect(rig.field.string == "Hello there! and more")
    }

    /// A key divides the speech pieces; unchanged words before it remain conditionally correctable.
    @Test func aRevisionOfUntouchedWordsBeforeAUserKeyStillLands() {
        var rig = QueueRig(FakeField(""))
        rig.queue.enqueue(snap(1, "first words"))
        rig.drain()
        rig.queue.enqueue(.insert("."))
        rig.queue.enqueue(snap(2, "first words then more"))
        rig.drain()
        #expect(rig.field.string == "first words. then more")
        let from = rig.sent.count
        rig.queue.enqueue(snap(3, "First words then more", complete: true))
        rig.drain()
        #expect(rig.field.string == "First words. then more")
        #expect(rig.sent[from...].allSatisfy { if case .deleteBackward(let n) = $0.op { n == 1 } else { true } })
        #expect(rig.drops.map(\.reason) == [.userEdited])
    }

    @Test func aRegionTheUserTypedIntoDropsItsRevisionWithAnEvent() {
        var rig = QueueRig(FakeField(""))
        rig.queue.enqueue(snap(1, "alpha beta"))
        rig.drain()
        rig.queue.enqueue(.move(-2))
        rig.queue.enqueue(.insert("Z"))
        rig.drain()
        rig.queue.enqueue(snap(2, "alpha gamma", complete: true))
        rig.drain()
        #expect(rig.field.string == "alpha beZta")
        #expect(rig.drops.first?.text == "alpha gamma")
        #expect(rig.drops.first?.reason == .userEdited)
    }

    /// The head's partial word grows into the whole word later: a key in between finishes the word first.
    @Test func aWordCutShortByAKeyIsFinishedFirst() {
        var rig = QueueRig(FakeField(""), config: .init())
        rig.queue.enqueue(snap(1, "wonder"))
        rig.drain()
        rig.queue.enqueue(snap(2, "wonderful"))
        rig.queue.enqueue(.insert("x"))
        rig.drain()
        #expect(rig.field.string == "wonderful x")
    }

    @Test func emojiMoveAsOneUnitInAFieldThatSaysSo() {
        var field = FakeField("")
        field.movesByCharacters = true
        var rig = QueueRig(field)
        rig.queue.enqueue(snap(1, "ok 👍 fine"))
        rig.drain()
        rig.queue.enqueue(snap(2, "OK 👍 fine"))
        rig.drain()
        #expect(rig.field.string == "OK 👍 fine")
    }

    @Test func safarisBlockEchoStillConfirms() {
        var field = FakeField("Title\n")
        field.blockEcho = true
        var rig = QueueRig(field)
        rig.queue.enqueue(snap(1, "body text here"))
        rig.drain()
        rig.queue.enqueue(snap(2, "body test here"))
        rig.drain()
        #expect(rig.field.string == "Title\nbody test here")
        #expect(!rig.events.contains { $0.event == .resync(.reseeded) })
    }

    /// A line repeated further down: Safari's window starts at the caret's block ("\n " echo). Reaching back past the
    /// known text's start, it also fits the first line, so it pins neither (it never pinned the first line alone).
    @Test func aBlockEchoOfARepeatedLineDoesNotPinTheFirstLine() {
        let text = Array("- maple light\n- maple ligh")
        #expect(FieldMatch.positions(in: text, reportedBefore: "\n - maple ligh", reportedAfter: "") == [12, 26])
        // A repeated line ending the field, typed take by take into a list: it lands whole.
        var field = FakeField("")
        field.blockEcho = true
        var rig = QueueRig(field, config: .init())
        for key in "- " { rig.queue.enqueue(.insert(String(key))); rig.run(ms: 66) }
        rig.queue.enqueue(snap(1, "maple light", run: "a"))
        rig.drain()
        for key in "\n- " { rig.queue.enqueue(.insert(String(key))); rig.run(ms: 66) }
        rig.queue.enqueue(snap(1, "maple light", run: "b"))
        rig.drain()
        #expect(rig.field.string == "- maple light\n- maple light")
    }

    @Test func aTapElsewhereClosesTheRegionAndLaterWordsStartAtTheNewCursor() {
        var rig = QueueRig(FakeField("Start. End."))
        rig.field.tap(at: 6)
        rig.queue.enqueue(snap(1, "middle"))
        rig.drain()
        #expect(rig.field.string == "Start. middle End.")
        rig.field.tap(at: rig.field.text.count)
        rig.run(ms: 100)
        rig.queue.enqueue(snap(2, "middle and tail"))
        rig.drain()
        #expect(rig.field.string == "Start. middle End. and tail")
    }

    @Test func aMagicEditWithAScopeLongerThanTheWindowLands() {
        let long = String(repeating: "word ", count: 40)
        var field = FakeField(long + "teh end")
        field.window = 30
        var rig = QueueRig(field)
        rig.queue.enqueue(FieldQueue.Edit(id: "m", kind: .magic, before: "Begin " + long + "teh end", after: "",
                                          target: "Begin " + long + "the end"))
        rig.drain()
        // The scope's start is not in the field: the edit's text there is not trusted beyond what the field confirms.
        #expect(rig.field.string.hasSuffix("the end") || rig.drops.count == 1)
    }

    /// The caret never goes back for the space after a take typed in front of text: it goes in at the take's end once
    /// the take is done (an insert at the caret).
    @Test func aRunInFrontOfTextGetsItsSpaceAfterItWhenTheTakeIsDone() {
        var rig = QueueRig(FakeField("Hello world", caret: 6))
        rig.queue.enqueue(snap(1, "big"))
        rig.drain()
        #expect(rig.field.string == "Hello bigworld")
        rig.queue.enqueue(snap(2, "big wide", complete: true))
        rig.drain()
        #expect(rig.field.string == "Hello big wide world")
        #expect(rig.field.caret == 15)
        #expect(!rig.sent.contains { if case .move = $0.op { true } else { false } })
    }

    /// A take never splits a word: one started with the caret inside a word goes in after the word (the caret moves to
    /// its end first; nobody acted in the take yet).
    @Test func aTakeStartedInsideAWordGoesAfterTheWord() {
        var rig = QueueRig(FakeField("the wagon", caret: 7))
        rig.queue.enqueue(snap(1, "pocket will", complete: true))
        rig.drain()
        #expect(rig.field.string == "the wagon pocket will")
        #expect(rig.drops.isEmpty)
    }

    /// Words that go on after the user put the caret inside a word go in at the caret with a space on each side (no
    /// move after the user acted): nothing of the take is lost from the field.
    @Test func wordsAfterTheUserPutTheCaretInsideAWordGoInWithSpaces() {
        var rig = QueueRig(FakeField(""))
        rig.queue.enqueue(snap(1, "alpha beta"))
        rig.drain()
        rig.queue.enqueue(.move(-3))
        rig.drain()
        let moved = rig.sent.count
        rig.queue.enqueue(snap(2, "alpha beta gamma", complete: true))
        rig.drain()
        #expect(rig.field.string == "alpha b gamma eta")
        #expect(!rig.sent[moved...].contains { if case .move = $0.op { true } else if case .deleteBackward = $0.op { true } else { false } })
        #expect(rig.drops.map(\.reason) == [.userEdited])
    }

    /// Revised recognizer words still align later speech after a user key; the user's letter survives.
    @Test(arguments: [false, true])
    func aRevisedWordAfterTheUserActedDoesNotStopTheTake(safari: Bool) {
        var field = FakeField("")
        field.hostDelays = safari
        var rig = QueueRig(field, config: .init())
        rig.queue.enqueue(snap(1, "check the forecast"))
        rig.drain()
        rig.queue.enqueue(.insert("x"))
        rig.drain()
        rig.queue.enqueue(snap(2, "check the forecast whether"))
        rig.drain()
        rig.queue.enqueue(snap(3, "check the forecast weather"))
        rig.drain()
        rig.queue.enqueue(snap(4, "check the forecast weather is fine today"))
        rig.drain()
        rig.queue.enqueue(snap(5, "check the forecast weather is fine today and their boat"))
        rig.drain()
        rig.queue.enqueue(snap(6, "check the forecast weather is fine today and there boat sails", complete: true))
        rig.drain()
        #expect(rig.field.string == "check the forecastx weather is fine today and there boat sails")
        #expect(rig.sent.allSatisfy { if case .deleteBackward(let n) = $0.op { n == 1 } else { true } })
        #expect(rig.drops.map(\.reason) == [.userEdited])
    }

    /// The stop's swap lands and the queue says so before it goes idle (the keyboard stops stepping then, and its
    /// "Applying edits…" waits for this acknowledgement).
    @Test(arguments: [false, true])
    func aSwappedTakeIsAcknowledgedBeforeTheQueueGoesIdle(safari: Bool) {
        var field = FakeField("")
        field.hostDelays = safari
        var rig = QueueRig(field)
        rig.queue.enqueue(snap(1, "um the boat is ready"))
        rig.queue.enqueue(snap(2, "um the boat is ready", complete: true))
        rig.drain()
        rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: 3, segments: [
            .init(id: 0, text: "The boat is ready.", cleaned: true, final: true),
        ], complete: true))
        var ticks = 0
        repeat { rig.tick(); ticks += 1 } while !(rig.queue.isIdle && !rig.queue.hasOpInFlight && rig.field.settled) && ticks < 400
        #expect(rig.field.string == "The boat is ready.")
        #expect(rig.events.contains { $0.event == .liveApplied(runID: "r", version: 3, complete: true) })
        #expect(rig.drops.isEmpty)
    }

    @Test func aRunAfterASentenceEndStartsWithACapitalAndASpace() {
        var rig = QueueRig(FakeField("Done."), config: .init(capitalization: .sentences))
        rig.queue.enqueue(snap(1, "next one"))
        rig.drain()
        #expect(rig.field.string == "Done. Next one")
    }

    @Test func safarisTimingNeverReordersOrStallsReports() {
        var field = FakeField("I think the plan is fine. ")
        field.hostDelays = true
        var rig = QueueRig(field, config: .init())
        rig.queue.enqueue(snap(1, "and then we go"))
        rig.run(ms: 400)
        rig.queue.enqueue(snap(2, "and than we go home"))
        rig.queue.enqueue(.insert("!"))
        rig.drain()
        #expect(rig.field.reorders == 0)
        #expect(rig.field.string.contains("!"))
        #expect(rig.queue.modelText == rig.field.string)
    }

    /// A rich editor puts a placeholder into a line that becomes empty (or drops its list item): a replacement of a whole
    /// line keeps one old grapheme until the new text stands.
    @Test(arguments: [false, true])
    func aWholeLineReplacementNeverLeavesTheLineEmpty(safari: Bool) {
        var field = FakeField("milk\neggs\nbread", caret: 9)
        field.hostDelays = safari
        field.blockEcho = true
        var rig = QueueRig(field, config: .init())
        rig.run(ms: 100)
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: "milk\neggs", after: "\nbread",
                                          target: "milk\nbutter\nbread", cursorAtEnd: false))
        var emptied = false
        for _ in 0..<200 {
            rig.tick()
            if rig.field.string.contains("\n\n") { emptied = true }
        }
        #expect(rig.field.string == "milk\nbutter\nbread")
        #expect(!emptied)
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: "milk\nbutter", after: "\nbread", target: "milk\nbutter\nBREAD",
                                          cursorAtEnd: false))
        for _ in 0..<200 {
            rig.tick()
            if rig.field.string.hasSuffix("\n") { emptied = true }
        }
        #expect(rig.field.string == "milk\nbutter\nBREAD")
        #expect(!emptied)
    }
}

@Suite struct FieldQueueSafariTimingTests {
    /// UAT (Simulator Safari): cleanup capitalises a dictated line while the user taps the start and types. The proxy
    /// echoes every edit at once, and a report after the tap shows the text from before the last confirmed edits.
    /// Nothing may be lost ("QThe eeting" lost the "M"), and the key lands where the user tapped.
    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 6, 7, 8])
    func aTapDuringCleanupLosesNoCharacterAndTheKeyLandsAtTheTap(seed: UInt64) {
        let raw = "the meeting is at three pm tomorrow and we need slides"
        let cleaned = "The Meeting Is At Three Pm Tomorrow And We Need Slides"
        var field = FakeField("")
        field.hostDelays = true
        field.staleReportsAfterTap = 3
        field.lagTicks = Int(seed % 3)
        var rig = QueueRig(field, config: .init())
        rig.queue.enqueue(snap(1, raw))
        rig.drain()
        #expect(rig.field.string == raw)
        rig.queue.enqueue(snap(2, cleaned, complete: true))
        rig.run(ms: 300 + Double(seed) * 120)
        rig.field.tap(at: 0)
        rig.run(ms: 100)
        rig.queue.enqueue(.insert("Q"))
        rig.drain()
        #expect(rig.field.reorders == 0)
        // No keyboard can see a tap inside a chunk's landing window: what is still on its way may land at the tap (with
        // this host's stale reports after a tap even a cleaned letter, its old one gone at the place; known limit, see
        // docs/field-editing.md). The user's input is never lost: the key lands once, nothing of the user's is deleted,
        // and every word of the take is still there.
        #expect(rig.field.string.filter { $0 == "Q" }.count == 1)
        #expect(!rig.field.deletions.contains { $0.origin == .initial || $0.origin == .user })
        let words = Set(rig.field.string.replacingOccurrences(of: "Q", with: "").lowercased().split { !$0.isLetter }.map(String.init))
        let missing = raw.split(separator: " ").filter { word in !words.contains { $0.contains(word.dropFirst()) } }
        #expect(missing.isEmpty, "\(rig.field.string.debugDescription)")
    }

    /// UAT: two keys within 0.1 s, a tap, a key, then backspace, against Safari's timing: every key lands once, in order.
    @Test func aRapidBurstOfKeysAndATapLandsEveryKeyOnce() {
        var field = FakeField("alpha bravo charlie delta echo")
        field.hostDelays = true
        field.staleReportsAfterTap = 2
        var rig = QueueRig(field, config: .init())
        rig.run(ms: 100)
        rig.queue.enqueue(.insert("x")); rig.tick(); rig.queue.enqueue(.insert("y"))
        rig.run(ms: 400)
        rig.field.tap(at: 6)
        rig.run(ms: 66)
        rig.queue.enqueue(.insert("z"))
        rig.run(ms: 66)
        rig.queue.enqueue(.deleteBackward)
        rig.drain()
        #expect(rig.field.reorders == 0)
        #expect(rig.field.string == "alpha bravo charlie delta echoxy")
    }
}

/// Speed under Safari's measured timing: one grapheme per op, at a pace that finishes the backlog in about a second.
@Suite struct FieldQueueSpeedTests {
    private func rig(_ text: String = "") -> QueueRig {
        var field = FakeField(text)
        field.hostDelays = true
        return QueueRig(field, config: .init())
    }

    private func inserts(_ rig: QueueRig, from: Int = 0) -> [(ms: Double, text: String)] {
        rig.sent[from...].compactMap { if case .insert(let s) = $0.op { ($0.ms, s) } else { nil } }
    }

    @Test func aBacklogGoesInOneInsert() {
        var rig = rig()
        let line = "we need slides for the meeting tomorrow at three, and the budget numbers from last week; "
            + "anna checks whether the room is free in the afternoon"
        rig.queue.enqueue(snap(1, line))
        rig.drain()
        #expect(rig.field.string == line)
        #expect(inserts(rig).map(\.text) == [line])
        #expect(rig.field.reorders == 0)
    }

    @Test func dictationAtSpeechRateKeepsUp() {
        var rig = rig()
        // About 14 characters a second, a word every ~0.4 s.
        let words = "we need slides for the meeting tomorrow at three and the budget numbers from last week".split(separator: " ")
        var text = ""
        for (i, word) in words.enumerated() {
            text += (text.isEmpty ? "" : " ") + word
            rig.queue.enqueue(snap(i + 1, text))
            rig.run(ms: 400)
        }
        let spoken = rig.clockMs
        rig.drain()
        let lag = rig.sent.last.map { $0.ms - spoken } ?? 0
        print("speed: dictation of \(text.count) chars at speech rate, last op \(Int(lag)) ms after the last word")
        #expect(rig.field.string == text)
        #expect(lag < 1_500, "the typewriter trails speech by the backlog's budget at most")
    }

    @Test func aOneWordSonioxFixNearTheCaretRetypesFromTheChangeOnly() {
        var rig = rig()
        rig.queue.enqueue(snap(1, "I will meet you on Thursday at noon in the lobby"))
        rig.drain()
        let from = rig.sent.count
        let start = rig.clockMs
        rig.queue.enqueue(snap(2, "I will meet you on Friday at noon in the lobby"))
        rig.drain()
        let took = (rig.sent.last?.ms ?? start) - start
        print("speed: one-word Soniox fix near the caret took \(Int(took)) ms (\(rig.sent.count - from) ops)")
        #expect(rig.field.string == "I will meet you on Friday at noon in the lobby")
        let edits = rig.sent[from...].map(\.op)
        // One delete back to the change, then the rest typed again; the words before it stay.
        #expect(edits.filter { if case .deleteBackward = $0 { true } else { false } } == [.deleteBackward(29)])
        #expect(inserts(rig, from: from).map(\.text).joined() == "Friday at noon in the lobby")
        #expect(!edits.contains { if case .move = $0 { true } else { false } })
        #expect(took < 3_000)
    }

    @Test func magicUppercasingPreservesEverySpaceAndPunctuationMark() {
        let sentence = "the meeting is at three pm tomorrow, we need the slides"
        var rig = rig(sentence)
        rig.run(ms: 100)
        let from = rig.sent.count
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: sentence, target: sentence.uppercased(), cursorAtEnd: false))
        let start = rig.clockMs
        rig.drain()
        let took = (rig.sent.last?.ms ?? start) - start
        print("speed: uppercase Magic of \(sentence.count) chars took \(Int(took)) ms, \(Int(took / Double(sentence.count))) ms a character")
        #expect(rig.field.string == sentence.uppercased())
        let ops = rig.sent[from...].map(\.op)
        // Only letters change case. Spaces and punctuation are never deleted or retyped for a cheaper block.
        let deleted = ops.reduce(0) { if case .deleteBackward(let n) = $1 { $0 + n } else { $0 } }
        #expect(deleted == sentence.filter { $0.isLowercase }.count)
        #expect(inserts(rig, from: from).map(\.text).joined().allSatisfy { $0.isUppercase })
        #expect(inserts(rig, from: from).map(\.text).joined().count == sentence.filter { $0.isLowercase }.count)
        #expect(rig.field.reorders == 0)
        #expect(took < 1_000, "one chunk per group of nearby changes, no settle waits")
    }

    @Test func aCleanupOfTwentyScatteredChangesInThreeHundredCharacters() {
        let raw = "so i think we should meet on thursday to talk about the budget and then maybe go over the slides for the "
            + "client meeting next week because last time we ran out of time and nobody had seen the numbers yet so it would "
            + "be good to send them around before and also check with anna whether the room is free in the afternoon ok"
        let cleaned = "So, I think we should meet on Thursday to talk about the budget, and then maybe go over the slides for the "
            + "client meeting next week. Last time, we ran out of time and nobody had seen the numbers yet, so it would "
            + "be good to send them around before. Also, check with Anna whether the room is free in the afternoon. OK."
        var rig = rig()
        rig.queue.enqueue(snap(1, raw))
        rig.drain()
        let from = rig.sent.count
        let start = rig.clockMs
        rig.queue.enqueue(snap(2, cleaned, complete: true))
        rig.drain()
        let took = (rig.sent.last?.ms ?? start) - start
        let moves = rig.sent[from...].filter { if case .move = $0.op { true } else { false } }.count
        print("speed: cleanup of \(raw.count) chars, \(moves - 1) jumps, took \(Int(took)) ms (\(rig.sent.count - from) ops)")
        #expect(rig.field.string == cleaned)
        #expect(rig.field.reorders == 0)
        #expect(took < 15_000)
    }

    // MARK: Late cleanups and Magic against the run's own edits (UAT, Safari, real Claude cleanup)

    private static let line = "please remember to send the quarterly report to the whole team before Friday afternoon"

    /// Dictates the line in three stretches, deleting in the pauses as the UAT did: the "e" of "whole", all of "Friday",
    /// the end of "afternoon".
    private static func typedWithDeletes() -> QueueRig {
        var rig = QueueRig(FakeField(""), config: .init())
        var version = 0
        func type(until suffix: String, thenDelete count: Int, rig: inout QueueRig) {
            let end = line.range(of: suffix)!.upperBound
            version += 1
            rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: version, segments: [.init(id: 0, text: String(line[..<end]), final: false)]))
            while !rig.field.string.hasSuffix(suffix), rig.clockMs < 30_000 { rig.tick() }
            for _ in 0..<count { rig.queue.enqueue(.deleteBackward) }
            rig.drain()
        }
        type(until: "whole", thenDelete: 1, rig: &rig)
        type(until: "Friday", thenDelete: 6, rig: &rig)
        type(until: "afternoon", thenDelete: 2, rig: &rig)
        rig.drain()
        return rig
    }

    @Test func lateCleanupPreservesDeletedWordsAndReturnsTheUsersCaret() {
        var rig = Self.typedWithDeletes()
        #expect(rig.field.string == "please remember to send the quarterly report to the whol team before afterno")
        // The user taps right after "please"; the cleanup arrives much later.
        rig.field.tap(at: 6)
        rig.run(ms: 1_000)
        let from = rig.events.count
        rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: 4, segments: [
            .init(id: 0, text: "Please remember to send the quarterly report to the whole team before Friday afternoon.", cleaned: true, final: true),
        ], complete: true))
        let drained = rig.drain(); #expect(drained)
        // Independent corrections land without restoring deleted user words or disturbing their caret.
        #expect(rig.field.string == "Please remember to send the quarterly report to the whol team before afterno.")
        #expect(rig.events[from...].allSatisfy { if case .sent(.deleteBackward(let n), _) = $0.event { n == 1 } else { true } })
        #expect(rig.queue.userCursor == 6 && rig.field.caret == 6)
        #expect(rig.events.contains { $0.event == .liveApplied(runID: "r", version: 4, complete: true) })
        #expect(rig.drops.map(\.reason) == [.userEdited])
    }

    @Test func cleanupWorksAroundADeletedWordAndMovedCaret() {
        var rig = QueueRig(FakeField(""))
        rig.queue.enqueue(snap(1, "alpha beta gamma delta"))
        rig.drain()
        // The user deletes the "a" of "delta" (at the region's end), then moves before "gamma".
        rig.queue.enqueue(.deleteBackward)
        rig.queue.enqueue(.move(-10))
        rig.drain()
        rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: 2, segments: [
            .init(id: 0, text: "Alpha beta, gamma Delta.", cleaned: true, final: true),
        ], complete: true))
        rig.drain()
        #expect(rig.field.string == "Alpha beta, gamma delt.")
        #expect(rig.drops.map(\.reason) == [.userEdited])
    }

    @Test func newRawWordsAfterATapStillStartAtTheUsersCursor() {
        var rig = QueueRig(FakeField(""))
        rig.queue.enqueue(snap(1, "first words"))
        rig.drain()
        rig.queue.enqueue(.deleteBackward)
        rig.drain()
        rig.field.tap(at: 0)
        rig.run(ms: 500)
        rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: 2, segments: [
            .init(id: 0, text: "first words", final: true), .init(id: 1, text: "more", final: true),
        ], complete: true))
        rig.drain()
        #expect(rig.field.string == "more first word")
    }

    /// Magic read the field while the run's cleanup was still on its way; the cleanup landed before the result came.
    @Test func magicReadBeforeACleanupLandsOverIt() {
        var rig = QueueRig(FakeField(""), config: .init())
        rig.queue.enqueue(snap(1, "please send the report"))
        rig.drain()
        rig.queue.markRead("i1")
        rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: 2, segments: [
            .init(id: 0, text: "Please send the report.", cleaned: true, final: true),
        ], complete: true))
        rig.drain()
        #expect(rig.field.string == "Please send the report.")
        rig.queue.enqueue(FieldQueue.Edit(id: "m", kind: .magic, before: "please send the report", target: "Bitte sende den Bericht.",
                                          cursorAtEnd: false, readID: "i1"))
        rig.drain()
        #expect(rig.field.string == "Bitte sende den Bericht.")
        #expect(rig.applied == ["m"])
        #expect(rig.drops.isEmpty)
    }

    @Test func magicKeepsTheCleanupsChangesItDoesNotTouch() {
        var rig = QueueRig(FakeField(""))
        rig.queue.enqueue(snap(1, "please send the report to anna"))
        rig.drain()
        rig.queue.markRead("i1")
        rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: 2, segments: [
            .init(id: 0, text: "Please send the report to Anna.", cleaned: true, final: true),
        ], complete: true))
        rig.drain()
        rig.queue.enqueue(FieldQueue.Edit(id: "m", kind: .magic, before: "please send the report to anna", target: "please send the summary to anna",
                                          cursorAtEnd: false, readID: "i1"))
        rig.drain()
        #expect(rig.field.string == "Please send the summary to Anna.")
        #expect(rig.applied == ["m"])
    }

    @Test func magicIsCancelledOnlyByTheUsersChangeToItsScope() {
        var rig = QueueRig(FakeField(""))
        rig.queue.enqueue(snap(1, "please send the report"))
        rig.drain()
        rig.queue.markRead("i1")
        rig.queue.enqueue(.move(-3))
        rig.queue.enqueue(.insert("x"))
        rig.drain()
        rig.queue.enqueue(FieldQueue.Edit(id: "m", kind: .magic, before: "please send the report", target: "PLEASE SEND THE REPORT",
                                          cursorAtEnd: false, readID: "i1"))
        rig.drain()
        #expect(rig.field.string == "please send the repxort")
        #expect(rig.drops.map(\.reason) == [.userEdited])
    }
}
