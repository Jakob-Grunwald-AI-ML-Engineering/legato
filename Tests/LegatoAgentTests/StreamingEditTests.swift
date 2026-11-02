import Foundation
import Synchronization
import Testing
import LegatoClaude
import LegatoRoom
import LegatoComposerDoc
@testable import LegatoAgent

// MARK: Progressive parser

@Test func partialTreeKeepsCompletedFieldsAndTheGrowingString() {
    let t = PartialJSONTree(parsing: #"{"after":"L1","lines":["one two","three fo"#)
    #expect(t.closed("after") && !t.closed("lines") && !t.complete)
    #expect(t.open == [.key("lines"), .index(1)])
    #expect(t.strings("lines")?.items == ["one two", "three "])   // the unfinished word waits
    let done = PartialJSONTree(parsing: #"{"after":"L1","lines":["one two","three four"]}"#)
    #expect(done.complete && done.open.isEmpty && done.strings("lines")?.items == ["one two", "three four"])
}

@Test func partialTreeDropsUnfinishedScalars() {
    #expect(PartialJSONTree(parsing: #"{"version":1"#).value["version"] == nil)
    #expect(PartialJSONTree(parsing: #"{"version":12,"x":tr"#).closed("version"))
    #expect(PartialJSONTree(parsing: #"{"version":12,"x":tr"#).value["x"] == nil)
    #expect(PartialJSONTree(parsing: "").value == .null)
    #expect(PartialJSONTree(parsing: #"{"old":"abc"#).closed("old") == false)
}

@Test func partialTreeHoldsBackSplitEscapesAndSurrogates() throws {
    let source = #"{"new":"a\nb \"q\" é 😀 \\ end"}"#
    let expected = try #require(JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))["new"])
    guard case .string(let full) = expected else { return }
    let scalars = Array(source)
    for cut in 0...scalars.count {
        let tree = PartialJSONTree(parsing: String(scalars[..<cut]))
        guard let text = tree.string("new") else { continue }
        #expect(full.hasPrefix(text), "cut \(cut): \(text.debugDescription)")
        #expect(!text.contains("\u{FFFD}"))
    }
    #expect(PartialJSONTree(parsing: source).string("new") == full)
}

@Test func wholeWordsOnlyShowCompletedWords() {
    #expect(PartialJSONTree.wholeWords("one tw") == "one ")
    #expect(PartialJSONTree.wholeWords("one two ") == "one two ")
    #expect(PartialJSONTree.wholeWords("one") == "")
}

// MARK: Every op: preview grows, final equals the non-streaming apply

private struct Fixture {
    let room = Room()
    var lines: [Line] = []
    init() async throws {
        for text in ["alpha beta gamma", "delta epsilon", "zeta eta"] {
            _ = try await room.appendSegment(words: text.split(separator: " ").map { Word(text: String($0)) })
        }
        lines = await room.documentSnapshot.lines
    }
}
private func shape(_ s: DocumentSnapshot) -> [String] { s.lines.map { "\($0.kind.rawValue) v\($0.version) \($0.text)" } }
private func identity(_ s: DocumentSnapshot) -> [String] { s.lines.map { "\($0.id):" + $0.words.map { "\($0.id)=\($0.text)" }.joined(separator: ",") } }
private func versions(_ lines: [Line]) -> String { "[" + lines.map { #"{"line":"\#($0.id)","version":\#($0.version)}"# }.joined(separator: ",") + "]" }

/// JSON for one tool call per op, written in the order a model emits it.
private func calls(_ l: [Line]) -> [(name: String, json: String)] { [
    ("insert_lines", #"{"after":"\#(l[0].id)","lines":["one two three four five","six seven eight nine"]}"#),
    ("replace_lines", #"{"from":"\#(l[1].id)","to":"\#(l[2].id)","lines":["fresh start here now","second fresh line today"],"versions":\#(versions([l[1], l[2]]))}"#),
    ("replace_in_line", #"{"line":"\#(l[0].id)","old":"beta","new":"bright shiny new thing","version":\#(l[0].version)}"#),
    ("delete_lines", #"{"from":"\#(l[1].id)","to":"\#(l[1].id)","versions":\#(versions([l[1]]))}"#),
    ("move_lines", #"{"from":"\#(l[2].id)","to":"\#(l[2].id)","after":"\#(l[0].id)","versions":\#(versions([l[2]]))}"#),
    ("set_kind", #"{"lines":["\#(l[1].id)"],"kind":"h2","versions":\#(versions([l[1]]))}"#),
] }

private func words(_ s: DocumentSnapshot) -> [String: String] {
    Dictionary(s.lines.flatMap(\.words).map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
}

@Test(arguments: ["insert_lines", "replace_lines", "replace_in_line", "delete_lines", "move_lines", "set_kind"])
func streamedOpEndsExactlyWhereTheNonStreamingApplyDoes(name: String) async throws {
    let streamed = try await Fixture(), plain = try await Fixture()
    let json = try #require(calls(streamed.lines).first { $0.name == name }).json
    let plainInput = try #require(calls(plain.lines).first { $0.name == name }).json
    let seed = UUID().uuidString
    let base = await streamed.room.documentSnapshot
    var previous = base, changed = false, sawPreview = false
    let characters = Array(json)
    for end in stride(from: 3, through: characters.count, by: 3) + [characters.count] {
        let tree = PartialJSONTree(parsing: String(characters[..<end]))
        let edit = StreamingEdit.edit(name: name, tree: tree, base: base, seed: seed, phase: .pause, allowedLineIDs: nil)
        await streamed.room.setProvisional(block: 0, edit)
        let shown = await streamed.room.draftSnapshot
        // The authoritative document never moves while previewing.
        #expect(await streamed.room.documentSnapshot == base)
        if shown != base {
            sawPreview = true
            // Within one op the preview only grows: once the first replacement word shows, no word is changed or removed.
            if changed { for (id, text) in words(previous) { #expect(words(shown)[id] == text, "\(name) lost \(text) at \(end)") } }
            changed = true
        }
        previous = shown
    }
    #expect(sawPreview)
    let final = await streamed.room.draftSnapshot
    let a = await ToolExecutor(room: streamed.room).execute(name: name, input: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
        groupID: "g", live: true, idSeed: seed)
    await streamed.room.dropProvisional(block: 0)
    let b = await ToolExecutor(room: plain.room).execute(name: name, input: try JSONDecoder().decode(JSONValue.self, from: Data(plainInput.utf8)),
        groupID: "g", live: true)
    #expect(!a.isError && !b.isError, "\(a.content) \(b.content)")
    let after = await streamed.room.documentSnapshot
    let expected = await plain.room.documentSnapshot
    #expect(shape(after) == shape(expected))
    // The preview's last state is the final state, ids included, so the swap re-animates nothing.
    #expect(identity(after) == identity(final))
    let draft = await streamed.room.draftSnapshot
    #expect(draft == after)
    #expect(!(await streamed.room.hasProvisional))
}

@Test func replaceKeepsOldTextUntilTheFirstReplacementWordThenShowsOnlyTheReplacement() async throws {
    let f = try await Fixture(), base = await f.room.documentSnapshot
    let json = #"{"from":"\#(f.lines[1].id)","to":"\#(f.lines[1].id)","lines":["brand new text"],"versions":\#(versions([f.lines[1]]))}"#
    func shown(_ cut: String) async -> String {
        let edit = StreamingEdit.edit(name: "replace_lines", tree: PartialJSONTree(parsing: cut), base: base, seed: "s", phase: .pause, allowedLineIDs: nil)
        await f.room.setProvisional(block: 0, edit); return await f.room.draftSnapshot.text
    }
    let head = String(json.prefix(while: { $0 != "[" }))
    #expect(await shown(head + #"["bran"#) == base.text)                       // no whole word yet
    #expect(await shown(head + #"["brand ne"#).contains("delta") == false)      // first word: old line swaps out
    #expect(await shown(head + #"["brand ne"#).contains("brand"))
    #expect(await shown(json) == "alpha beta gamma\nbrand new text\nzeta eta")
}

@Test func previewIsRefusedWhereTheAuthoritativeCallWould() async throws {
    let f = try await Fixture(), base = await f.room.documentSnapshot
    func edit(_ name: String, _ json: String, phase: WritingPhase = .pause, allowed: Set<String>? = nil) -> Room.ProvisionalEdit? {
        StreamingEdit.edit(name: name, tree: PartialJSONTree(parsing: json), base: base, seed: "s", phase: phase, allowedLineIDs: allowed)
    }
    let insert = #"{"lines":["a b c"]}"#
    #expect(edit("insert_lines", insert) != nil)
    #expect(edit("insert_lines", insert, phase: .quick) == nil)                              // quick pass defers it
    #expect(edit("insert_lines", #"{"after":"\#(f.lines[0].id)","lines":["x y "]}"#, allowed: [f.lines[1].id]) == nil)
    #expect(edit("insert_lines", #"{"lines":["a b c"#) == nil)                                // `after` may still arrive
    #expect(edit("replace_in_line", #"{"line":"nope","old":"a","new":"b c"}"#) != nil)       // unknown ids fail in the document, not here
    await f.room.setProvisional(block: 0, edit("replace_in_line", #"{"line":"nope","old":"a","new":"b c"}"#))
    #expect(await f.room.draftSnapshot == base)
    // A stale version stated by the model gives no preview.
    await f.room.setProvisional(block: 0, edit("delete_lines", #"{"from":"\#(f.lines[1].id)","to":"\#(f.lines[1].id)","versions":[{"line":"\#(f.lines[1].id)","version":9}]}"#))
    #expect(await f.room.draftSnapshot == base)
}

@Test func laterAuthoritativeChangesKeepThePreviewOnTop() async throws {
    let f = try await Fixture(), base = await f.room.documentSnapshot
    let edit = StreamingEdit.edit(name: "replace_in_line", tree: PartialJSONTree(parsing: #"{"line":"\#(f.lines[0].id)","old":"beta","new":"bright light "}"#),
        base: base, seed: "s", phase: .pause, allowedLineIDs: nil)
    await f.room.setProvisional(block: 0, edit)
    let events = await f.room.subscribe(participant: .logger, channels: [.agentStatus, .docSnapshot])
    _ = try await f.room.appendSegment(words: [Word(text: "late")])      // dictation lands mid-stream
    #expect(await f.room.draftSnapshot.text == "alpha bright light gamma\ndelta epsilon\nzeta eta\nlate")
    var last: Envelope?
    for await event in events { last = event; if event.channel == .agentStatus { break } }
    #expect(last?.payload["event"] == .string("draft.provisional"))   // the preview is the last word, not the bare snapshot
}

// MARK: Runner: streaming, multi-tool turns, rollback

private final class ChunkedMessages: MessagesStreaming {
    /// Tool calls of the first request (name, JSON, delivered in `size`-character fragments).
    let calls: [(String, String)]; let size: Int; let failAfter: Int?
    let requests = Mutex<Int>(0)
    init(calls: [(String, String)], size: Int = 6, failAfter: Int? = nil) { self.calls = calls; self.size = size; self.failAfter = failAfter }
    struct Boom: Error {}
    func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        let first = requests.withLock { $0 += 1; return $0 == 1 }
        return AsyncThrowingStream { continuation in
            Task {
                func emit(_ type: String, _ json: JSONValue) {
                    continuation.yield(.init(event: type, data: String(decoding: try! JSONEncoder().encode(json), as: UTF8.self)))
                }
                guard first else {
                    emit("content_block_start", .object(["index": .number(0), "content_block": .object(["type": .string("text"), "text": .string("Done")])]))
                    continuation.finish(); return
                }
                var sent = 0
                for (index, call) in calls.enumerated() {
                    emit("content_block_start", .object(["index": .number(Double(index)), "content_block": .object(["type": .string("tool_use"), "id": .string("t\(index)"), "name": .string(call.0), "input": .object([:])])]))
                    let chars = Array(call.1)
                    for start in stride(from: 0, to: chars.count, by: size) {
                        if failAfter == sent { continuation.finish(throwing: Boom()); return }
                        sent += 1
                        emit("content_block_delta", .object(["index": .number(Double(index)), "delta": .object(["type": .string("input_json_delta"), "partial_json": .string(String(chars[start..<min(chars.count, start + size)]))])]))
                        try? await Task.sleep(for: .milliseconds(45))
                    }
                    emit("content_block_stop", .object(["type": .string("content_block_stop"), "index": .number(Double(index))]))
                }
                emit("message_stop", .object(["type": .string("message_stop")]))
                continuation.finish()
            }
        }
    }
}

private func runTurn(_ f: Fixture, client: ChunkedMessages) async throws -> (previews: [(snapshot: DocumentSnapshot, clear: Bool)], errors: Int) {
    let events = await f.room.subscribe(participant: .logger, channels: [.agentStatus])
    let seen = Mutex<[(DocumentSnapshot, Bool)]>([]), errors = Mutex(0)
    let collector = Task {
        for await event in events {
            if event.payload["event"] == .string("draft.provisional"), let s = try? event.payload["snapshot"]?.decode(DocumentSnapshot.self) {
                seen.withLock { $0.append((s, event.payload["clear"] != nil)) }
            }
            if event.payload["event"] == .string("error") { errors.withLock { $0 += 1 } }
        }
    }
    let runner = AgentRunner(room: f.room, client: client)
    await runner.start()
    _ = try await f.room.publish(channel: .userIntent, participant: .ui, payload: .string("Rewrite it"))
    for _ in 0..<300 {
        if client.requests.withLock({ $0 }) >= 2 || (client.failAfter != nil && errors.withLock { $0 } > 0) { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try await Task.sleep(for: .milliseconds(100))
    await runner.stop(); collector.cancel()
    return (seen.withLock { $0.map { (snapshot: $0.0, clear: $0.1) } }, errors.withLock { $0 })
}

@Test func runnerStreamsAMultiToolTurnIntoThePreviewAndLandsOnTheFinalDraft() async throws {
    let f = try await Fixture()
    let l = f.lines
    let client = ChunkedMessages(calls: [
        ("replace_in_line", #"{"line":"\#(l[0].id)","old":"beta","new":"bright shiny new thing","version":\#(l[0].version)}"#),
        ("replace_in_line", #"{"line":"\#(l[2].id)","old":"zeta","new":"theta iota kappa","version":\#(l[2].version)}"#),
    ])
    let (previews, errors) = try await runTurn(f, client: client)
    #expect(errors == 0)
    #expect(previews.filter { !$0.clear }.count >= 4)                      // it streamed, not one jump
    let texts = previews.map(\.snapshot.text)
    #expect(texts.contains { $0.contains("bright shiny") && !$0.contains("thing") })   // mid-op state
    #expect(texts.contains { $0.contains("bright shiny new thing") && $0.contains("zeta eta") })   // block 2 not yet
    #expect(texts.contains { $0.contains("theta iota") })
    #expect(await f.room.documentSnapshot.text == "alpha bright shiny new thing gamma\ndelta epsilon\ntheta iota kappa eta")
    #expect(previews.last?.clear == true)
    let landed = await f.room.documentSnapshot
    #expect(previews.last?.snapshot == landed)
    #expect(!(await f.room.hasProvisional))
    // After the first real call lands, the second block's preview is never replaced by a bare snapshot.
    #expect(!texts.dropFirst(texts.firstIndex { $0.contains("theta iota") } ?? texts.count).contains { $0 == "alpha bright shiny new thing gamma\ndelta epsilon\nzeta eta" })
}

@Test func aStreamFailureRevertsThePreviewToThePreTurnDraft() async throws {
    let f = try await Fixture(), base = await f.room.documentSnapshot
    let l = f.lines
    let client = ChunkedMessages(calls: [("replace_in_line", #"{"line":"\#(l[0].id)","old":"beta","new":"bright shiny new thing","version":\#(l[0].version)}"#)], size: 4, failAfter: 24)
    let (previews, errors) = try await runTurn(f, client: client)
    #expect(errors == 1)
    #expect(previews.contains { !$0.clear && $0.snapshot.text.contains("bright") })   // it had started to show
    #expect(previews.last?.clear == true)
    #expect(previews.last?.snapshot == base)
    #expect(await f.room.documentSnapshot == base)
    #expect(!(await f.room.hasProvisional))
}

@Test func cancellingTheRunnerMidStreamRevertsThePreview() async throws {
    let f = try await Fixture(), base = await f.room.documentSnapshot
    let l = f.lines
    let client = ChunkedMessages(calls: [("replace_in_line", #"{"line":"\#(l[0].id)","old":"beta","new":"bright shiny new thing and then some more words","version":\#(l[0].version)}"#)])
    let runner = AgentRunner(room: f.room, client: client)
    await runner.start()
    _ = try await f.room.publish(channel: .userIntent, participant: .ui, payload: .string("Rewrite it"))
    for _ in 0..<200 { if await f.room.hasProvisional { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(await f.room.hasProvisional)
    await runner.stop()
    for _ in 0..<200 { if !(await f.room.hasProvisional) { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(!(await f.room.hasProvisional))
    #expect(await f.room.draftSnapshot == base)
}
