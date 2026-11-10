import Foundation
import Testing
@testable import LegatoKeyboardCore

private func line(_ seq: Int, _ text: String, raw: String? = nil, status: DictationLineStatus = .cleaned, final: Bool = true, retracted: Bool = false) -> DictationLine {
    .init(lineID: "s-\(seq)", seq: seq, raw: raw ?? text, text: text, status: status, final: final, retracted: retracted)
}
private func publication(_ lines: DictationLine..., session: String = "s") -> DictationPublication {
    .init(sessionID: session, lines: lines)
}

/// A field that echoes the typist's own inserts, so only deliberate user edits differ from what it expects.
private struct Field {
    var text = ""
    mutating func run(_ typist: inout DictationTypist, ms: Double = 40, steps: Int = 200,
                      capitalization: AutoCapitalizationType = .sentences) -> [Int] {
        var acked: [Int] = []
        for _ in 0..<steps where typist.needsTicks {
            let step = typist.step(contextBefore: text, elapsedMs: ms, capitalization: capitalization)
            text = String(text.dropLast(step.deletes)) + step.inserts.joined()
            if let up = step.acknowledged { acked.append(up) }
        }
        return acked
    }
}

@Test func linesAreTypedInOrderWithSeparatorsAndSentenceCapitals() {
    var typist = DictationTypist()
    var field = Field()
    typist.accept(publication(line(1, "this is the second."), line(0, "hello there.")), acknowledged: nil)
    let acked = field.run(&typist)
    #expect(field.text == "Hello there. This is the second.")
    #expect(acked == [0, 1])
    #expect(typist.typedThrough == 1 && !typist.needsTicks)
}

@Test func aLineContinuesMidSentenceWithoutCapitalAndAfterANewlineWithoutASpace() {
    var typist = DictationTypist()
    var field = Field(text: "Dear Anna, ")
    typist.accept(publication(line(0, "i am late."), line(1, "\n"), line(2, "thanks")), acknowledged: nil)
    _ = field.run(&typist)
    #expect(field.text == "Dear Anna, i am late.\nThanks", "Mid-sentence stays lowercase; no space after a line break, and a capital at its start")

    var mid = DictationTypist()
    var other = Field(text: "We will meet")
    mid.accept(publication(line(0, "on friday, ok?")), acknowledged: nil)
    _ = other.run(&mid)
    #expect(other.text == "We will meet on friday, ok?")
}

@Test func punctuationLinesStickToThePreviousWord() {
    #expect(DictationTypist.prepare(", and then", contextBefore: "Hello", capitalization: .sentences) == ", and then")
    #expect(DictationTypist.prepare("world", contextBefore: "Hello", capitalization: .sentences) == " world")
    #expect(DictationTypist.prepare("hello", contextBefore: "", capitalization: .none) == "hello", "Fields without autocapitalisation stay as dictated")
}

@Test func theTypewriterRevealsAGrowingPrefixAndNeverTypesALineTwice() {
    var typist = DictationTypist()
    var field = Field()
    typist.accept(publication(line(0, "a fairly long dictated sentence goes here.")), acknowledged: nil)
    let first = typist.step(contextBefore: field.text, elapsedMs: 33, capitalization: .sentences)
    field.text += first.inserts.joined()
    #expect(!first.inserts.isEmpty && field.text.count < 42, "A tick reveals part of the line")
    #expect(first.acknowledged == nil)

    // The app republishes the same line (no ack yet) while it is being typed, and once more after.
    typist.accept(publication(line(0, "a fairly long dictated sentence goes here.")), acknowledged: nil)
    _ = field.run(&typist)
    typist.accept(publication(line(0, "a fairly long dictated sentence goes here."), line(1, "next.")), acknowledged: nil)
    _ = field.run(&typist)
    #expect(field.text == "A fairly long dictated sentence goes here. Next.")
}

@Test func aRestartedKeyboardSkipsWhatItAlreadyAcknowledged() {
    var typist = DictationTypist()
    var field = Field(text: "Hello.")
    typist.accept(publication(line(0, "hello."), line(1, "world.")), acknowledged: .init(sessionID: "s", upTo: 0))
    _ = field.run(&typist)
    #expect(field.text == "Hello. World.")

    var stale = DictationTypist()
    stale.accept(publication(line(0, "again."), session: "new"), acknowledged: .init(sessionID: "old", upTo: 5))
    #expect(stale.pendingCount == 1, "An ack of another session does not hide this session's lines")
}

@Test func aUserEditStopsTheCurrentLineAndLaterLinesFollowTheNewCursor() {
    var typist = DictationTypist()
    var field = Field()
    typist.accept(publication(line(0, "this long line is cut short by the user."), line(1, "second line.")), acknowledged: nil)
    let step = typist.step(contextBefore: field.text, elapsedMs: 33, capitalization: .sentences)
    field.text += step.inserts.joined()
    let typed = field.text
    #expect(typist.interrupt() == 0, "The rest of line 0 is dropped and acknowledged")
    field.text += "!" // the user typed a character
    _ = field.run(&typist)
    #expect(field.text == typed + "! Second line.", "Line 1 goes in after the user's text, capitalised as a sentence start is not met")
}

@Test func aCursorMoveInTheFieldIsNotAnEchoAndEndsTheLine() {
    var typist = DictationTypist()
    var field = Field(text: "Start of text. ")
    typist.accept(publication(line(0, "typing along happily until moved."), line(1, "after the move.")), acknowledged: nil)
    let step = typist.step(contextBefore: field.text, elapsedMs: 33, capitalization: .sentences)
    field.text += step.inserts.joined()
    // The user taps elsewhere: the text before the cursor is something else entirely.
    field.text = "Elsewhere in the note, "
    let acked = field.run(&typist, ms: 100)
    #expect(acked == [0, 1])
    #expect(field.text.hasPrefix("Elsewhere in the note, ") && field.text.hasSuffix("after the move."))
    #expect(!field.text.contains("happily until moved"))
}

@Test func aLaggingContextIsWaitedForNotTreatedAsAnEdit() {
    var typist = DictationTypist()
    typist.accept(publication(line(0, "lagging proxy example here.")), acknowledged: nil)
    let first = typist.step(contextBefore: "Hi ", elapsedMs: 33, capitalization: .none)
    #expect(!first.inserts.isEmpty)
    // The proxy still reports the old context for a few ticks: nothing is typed, nothing is dropped.
    for _ in 0..<3 {
        let wait = typist.step(contextBefore: "Hi ", elapsedMs: 33, capitalization: .none)
        #expect(wait.inserts.isEmpty && wait.acknowledged == nil)
    }
    let caughtUp = typist.step(contextBefore: "Hi " + first.inserts.joined(), elapsedMs: 33, capitalization: .none)
    #expect(!caughtUp.inserts.isEmpty)
}

@Test func flushTypesEverythingNowAndAcknowledgesIt() {
    var typist = DictationTypist()
    typist.accept(publication(line(0, "one."), line(1, "two."), line(2, "three.")), acknowledged: nil)
    let step = typist.flush(contextBefore: "", capitalization: .sentences)
    #expect(step.inserts.joined() == "One. Two. Three.")
    #expect(step.acknowledged == 2)
    #expect(!typist.needsTicks)
}

@Test func linkCodecAndPresenceContextRoundTrip() throws {
    let store = LinkStore(MemoryLinkStore())
    let link = DictationLink(store: store)
    #expect(link.read() == nil && link.acknowledged() == nil)
    let value = publication(line(0, "Hello.", raw: "hello", status: .raw), line(1, "World."))
    link.publish(value); link.acknowledge(.init(sessionID: "s", upTo: 0))
    #expect(link.read() == value && link.acknowledged() == .init(sessionID: "s", upTo: 0))

    let long = String(repeating: "x", count: 900) + "end"
    let presence = KeyboardPresence(visible: true, at: Date(), documentID: "d", surface: .typing, contextBefore: long)
    #expect(presence.contextBefore?.count == KeyboardPresence.contextLimit && presence.contextBefore?.hasSuffix("end") == true)
    store.write(presence, forKey: LinkChannel.Key.presence)
    #expect(store.read(KeyboardPresence.self, forKey: LinkChannel.Key.presence)?.contextBefore == presence.contextBefore)
    let legacy = Data(#"{"visible":true,"at":1}"#.utf8)
    #expect((try? JSONDecoder().decode(KeyboardPresence.self, from: legacy))?.contextBefore == nil)
}

@Test func aMovedCursorIsNeverTypedAtWhileTheTypistWaits() {
    var typist = DictationTypist()
    typist.accept(publication(line(0, "a long line that the user interrupts by tapping elsewhere."), line(1, "next.")), acknowledged: nil)
    let first = typist.step(contextBefore: "Note ", elapsedMs: 33, capitalization: .none)
    #expect(!first.inserts.isEmpty)
    // The field reports the real cursor: somewhere else. Not one more character may land there.
    var typed = 0, acked: [Int] = []
    for _ in 0..<20 {
        let step = typist.step(contextBefore: "Elsewhere ", elapsedMs: 33, capitalization: .none)
        if acked.isEmpty && step.acknowledged == nil { typed += step.inserts.count }
        if let up = step.acknowledged { acked.append(up) }
    }
    #expect(typed == 0)
    #expect(acked.first == 0, "The interrupted line is dropped once the echo fails to arrive")
}

@Test func aShortAndALongLineUseOneCharacterPerAnimatedStep() {
    for text in ["Short line.", String(repeating: "A much longer take with many words in it. ", count: 20)] {
        var typist = DictationTypist()
        var field = Field()
        typist.accept(publication(line(0, text)), acknowledged: nil)
        var ticks = 0
        while typist.needsTicks, ticks < text.count + 10 {
            let step = typist.step(contextBefore: field.text, elapsedMs: 33, capitalization: .none)
            #expect(step.inserts.joined().count <= 1)
            field.text += step.inserts.joined()
            ticks += 1
        }
        #expect(field.text == text.trimmingCharacters(in: .whitespaces))
        #expect(ticks >= text.trimmingCharacters(in: .whitespaces).count)
    }
}

@Test func aGrowingLineIsTypedAsItArrivesAndAcknowledgedOnlyOnceFinal() {
    var typist = DictationTypist()
    var field = Field()
    var acked: [Int] = []
    func frames(_ n: Int) {
        for _ in 0..<n where typist.needsTicks {
            let step = typist.step(contextBefore: field.text, elapsedMs: 33, capitalization: .sentences)
            field.text += step.inserts.joined()
            if let up = step.acknowledged { acked.append(up) }
        }
    }
    typist.accept(publication(line(0, "hello ", final: false)), acknowledged: nil)
    frames(40)
    #expect(field.text == "Hello" , "Trailing space of a growing line is not typed before the next word")
    #expect(acked.isEmpty && !typist.needsTicks, "Fully typed but not final: the typist idles until the next publication")
    typist.accept(publication(line(0, "hello there, how", final: false)), acknowledged: nil)
    frames(60)
    #expect(field.text == "Hello there, how" && acked.isEmpty)
    typist.accept(publication(line(0, "hello there, how are you?", final: false)), acknowledged: nil)
    frames(60)
    #expect(field.text == "Hello there, how are you?" && acked.isEmpty)
    typist.accept(publication(line(0, "hello there, how are you?", final: true)), acknowledged: nil)
    frames(5)
    #expect(acked == [0] && typist.typedThrough == 0 && !typist.needsTicks)
    typist.accept(publication(line(0, "hello there, how are you?")), acknowledged: nil)
    frames(5)
    #expect(field.text == "Hello there, how are you?", "A line is never typed twice")
}

@Test func aFastStreamPreservesEveryCharacterWhileTheTypewriterCatchesUp() {
    var typist = DictationTypist()
    var field = Field()
    var text = ""
    var lag: [Int] = []
    // A fast publication still reveals at most one character per animated step.
    for frame in 0..<60 {
        text += String(repeating: "x", count: 40)
        typist.accept(publication(line(0, text, final: false)), acknowledged: nil)
        let step = typist.step(contextBefore: field.text, elapsedMs: 33, capitalization: .none)
        #expect(step.inserts.joined().count <= 1)
        field.text += step.inserts.joined()
        if frame > 10 { lag.append(text.count - field.text.count) }
    }
    #expect(lag.last == text.count - field.text.count)
    typist.accept(publication(line(0, text, final: true)), acknowledged: nil)
    var ticks = 0
    while typist.needsTicks, ticks < text.count + 10 { field.text += typist.step(contextBefore: field.text, elapsedMs: 33, capitalization: .none).inserts.joined(); ticks += 1 }
    #expect(field.text == text)
    #expect(ticks >= text.count - 60)
}

@Test func reduceMotionTypesWhateverArrivedAtOnce() {
    var typist = DictationTypist()
    typist.accept(publication(line(0, "a growing line of words", final: false)), acknowledged: nil)
    let step = typist.step(contextBefore: "", elapsedMs: 33, capitalization: .none, animated: false)
    #expect(step.inserts.joined() == "a growing line of words" && step.acknowledged == nil)
    typist.accept(publication(line(0, "a growing line of words and more", final: true)), acknowledged: nil)
    let rest = typist.step(contextBefore: "a growing line of words", elapsedMs: 33, capitalization: .none, animated: false)
    #expect(rest.inserts.joined() == " and more" && rest.acknowledged == 0)
}

@Test func theNextLineWaitsBehindAGrowingOne() {
    var typist = DictationTypist()
    var field = Field()
    typist.accept(publication(line(0, "first take", final: false), line(1, "second.")), acknowledged: nil)
    _ = field.run(&typist)
    #expect(field.text == "First take", "Order holds: take 1 types only after take 0 is final")
    typist.accept(publication(line(0, "first take.", final: true), line(1, "second.")), acknowledged: nil)
    _ = field.run(&typist)
    #expect(field.text == "First take. Second.")
}

@Test func aRetractedLineErasesExactlyWhatWasTypedWhenTheFieldStillEchoesIt() {
    var typist = DictationTypist()
    var field = Field(text: "Dear Anna, ")
    typist.accept(publication(line(0, "this is the partial text", final: false)), acknowledged: nil)
    _ = field.run(&typist, steps: 60)
    #expect(field.text == "Dear Anna, this is the partial text")
    typist.accept(publication(line(0, "this is the partial text", final: true, retracted: true), line(1, "the whole take.")), acknowledged: nil)
    let erase = typist.step(contextBefore: field.text, elapsedMs: 33, capitalization: .none)
    #expect(erase.deletes == 1 && erase.inserts.isEmpty && erase.acknowledged == nil)
    field.text = String(field.text.dropLast(erase.deletes))
    var deleted = erase.deletes
    var acknowledged = false
    while !acknowledged, typist.needsTicks {
        let step = typist.step(contextBefore: field.text, elapsedMs: 33, capitalization: .none)
        #expect(step.deletes <= 1 && step.inserts.isEmpty)
        field.text = String(field.text.dropLast(step.deletes))
        deleted += step.deletes
        acknowledged = step.acknowledged == 0
    }
    #expect(deleted == "this is the partial text".count)
    #expect(field.text == "Dear Anna, ")
    #expect(acknowledged)
    _ = field.run(&typist)
    #expect(field.text == "Dear Anna, the whole take.")
}

@Test func aRetractedLineIsLeftAloneWhenTheFieldNoLongerEchoesIt() {
    var typist = DictationTypist()
    var field = Field(text: "Hi ")
    typist.accept(publication(line(0, "partial words here", final: false)), acknowledged: nil)
    _ = field.run(&typist, steps: 60)
    field.text += " and the user typed more"
    typist.accept(publication(line(0, "partial words here", final: true, retracted: true)), acknowledged: nil)
    var deleted = 0, acked: [Int] = []
    for _ in 0..<20 {
        let step = typist.step(contextBefore: field.text, elapsedMs: 33, capitalization: .none)
        deleted += step.deletes
        if let up = step.acknowledged { acked.append(up) }
    }
    #expect(deleted == 0 && acked == [0], "Nothing is deleted from text that is not ours alone; the line is acknowledged")
}

@Test func aRetractedLineThatNeverStartedIsJustAcknowledged() {
    var typist = DictationTypist()
    typist.accept(publication(line(0, "never typed", final: true, retracted: true)), acknowledged: nil)
    let step = typist.step(contextBefore: "x", elapsedMs: 33, capitalization: .none)
    #expect(step.deletes == 0 && step.inserts.isEmpty && step.acknowledged == 0)
}

@Test func theLineCodecKeepsFinalAndRetractedAndReadsOlderPublications() throws {
    let value = publication(line(0, "partial", final: false), line(1, "gone", final: true, retracted: true))
    let decoded = try JSONDecoder().decode(DictationPublication.self, from: JSONEncoder().encode(value))
    #expect(decoded == value && decoded.lines[0].final == false && decoded.lines[1].retracted)
    let old = Data(#"{"sessionID":"s","lines":[{"lineID":"s-0","seq":0,"raw":"a","text":"A.","status":"cleaned"}]}"#.utf8)
    let line = try #require(try JSONDecoder().decode(DictationPublication.self, from: old).lines.first)
    #expect(line.final && !line.retracted, "A line without the flags is whole and not retracted")
}

@Test func anAnimatedFinalCharacterIsAcknowledgedOnlyAfterItsEcho() {
    var typist = DictationTypist()
    typist.accept(publication(line(0, "👨‍👩‍👧")), acknowledged: nil)
    let sent = typist.step(contextBefore: "", elapsedMs: 33, capitalization: .none)
    #expect(sent.inserts == ["👨‍👩‍👧"])
    #expect(sent.acknowledged == nil)
    let stale = typist.step(contextBefore: "", elapsedMs: 33, capitalization: .none)
    #expect(stale.inserts.isEmpty && stale.acknowledged == nil)
    let confirmed = typist.step(contextBefore: "👨‍👩‍👧", elapsedMs: 33, capitalization: .none)
    #expect(confirmed.inserts.isEmpty && confirmed.acknowledged == 0)
}
