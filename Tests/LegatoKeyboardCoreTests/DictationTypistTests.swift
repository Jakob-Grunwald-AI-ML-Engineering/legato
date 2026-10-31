import Foundation
import Testing
@testable import LegatoKeyboardCore

private func line(_ seq: Int, _ text: String, raw: String? = nil, status: DictationLineStatus = .cleaned) -> DictationLine {
    .init(lineID: "s-\(seq)", seq: seq, raw: raw ?? text, text: text, status: status)
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
            text += step.inserts.joined()
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
