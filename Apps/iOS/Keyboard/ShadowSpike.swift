#if DEBUG
import Foundation
import UIKit

import LegatoKeyboardCore

/// SPIKE (debug only): can the keyboard keep a shadow document of the host field and edit it anywhere?
/// Commands arrive as JSON in the App Group (`Library/Caches/shadow-cmd.json`, copied there from the Mac with
/// devicectl) and are polled while the keyboard is on screen; results are appended to
/// `Library/Caches/shadow-spike.jsonl` in the same container. Not wired into dictation.
@MainActor
final class ShadowSpike {
    private let proxy: () -> (any UITextDocumentProxy)?
    private var poller: Task<Void, Never>?
    private var busy = false
    private var lastID = ""

    init(proxy: @escaping () -> (any UITextDocumentProxy)?) { self.proxy = proxy }

    func start() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await self?.pollOnce()
            }
        }
    }

    func stop() { poller?.cancel(); poller = nil }

    // MARK: Command plumbing

    private static var caches: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.de.gruenwald.legato")?
            .appending(path: "Library/Caches", directoryHint: .isDirectory)
    }
    private var commandURL: URL? { Self.caches?.appending(path: "shadow-cmd.json") }
    private var logURL: URL? { Self.caches?.appending(path: "shadow-spike.jsonl") }

    private func pollOnce() async {
        guard !busy, let url = commandURL, let data = try? Data(contentsOf: url),
              let cmd = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = cmd["id"] as? String, id != lastID else { return }
        lastID = id
        try? FileManager.default.removeItem(at: url)
        busy = true
        defer { busy = false }
        host = cmd["host"] as? String ?? "?"
        runID = id
        log(["event": "command", "cmd": cmd["cmd"] ?? "?", "args": cmd])
        switch cmd["cmd"] as? String {
        case "ping":
            let s = snapshot()
            log(["event": "ping", "before": s.before.utf16.count, "after": s.after.utf16.count,
                 "docID": proxy()?.documentIdentifier.uuidString ?? "nil"])
        case "type":
            proxy()?.insertText(cmd["text"] as? String ?? "")
            try? await Task.sleep(for: .milliseconds(200))
            let s = snapshot()
            log(["event": "typed-text", "before": s.before.utf16.count])
        case "walk":
            let a = await walk(label: "walk-1")
            let b = await walk(label: "walk-2")
            log(["event": "walk-agree", "textEqual": a.text == b.text, "offsetEqual": a.origOffset == b.origOffset,
                 "lenA": a.text.utf16.count, "lenB": b.text.utf16.count])
        case "replay":
            await replay(cmd)
        default:
            log(["event": "error", "message": "unknown command"])
        }
        log(["event": "done"])
    }

    private var host = "?"
    private var runID = ""

    private func log(_ fields: [String: Any]) {
        var f = fields
        f["ts"] = Date().timeIntervalSince1970
        f["host"] = host
        f["run"] = runID
        guard let url = logURL, JSONSerialization.isValidJSONObject(f),
              var data = try? JSONSerialization.data(withJSONObject: f, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }

    // MARK: Proxy access

    struct Snap: Equatable {
        var before: String
        var after: String
        var selected: String?
    }

    private func snapshot() -> Snap {
        let p = proxy()
        return Snap(before: p?.documentContextBeforeInput ?? "", after: p?.documentContextAfterInput ?? "", selected: p?.selectedText)
    }

    private var proxyWaits: [Double] = []
    private var proxyTimeouts = 0

    /// Polls until the context differs from `from` and holds still for two polls; true when it changed.
    @discardableResult
    private func settle(from: Snap, timeoutMs: Int = 500) async -> Bool {
        let start = Date()
        var changed = false
        var stable = 0
        var last = snapshot()
        while Date().timeIntervalSince(start) * 1000 < Double(timeoutMs) {
            try? await Task.sleep(for: .milliseconds(6))
            let now = snapshot()
            if now != from { changed = true }
            if now == last, changed { stable += 1; if stable >= 3 { break } } else { stable = 0 }
            last = now
        }
        proxyWaits.append(Date().timeIntervalSince(start) * 1000)
        if !changed { proxyTimeouts += 1 }
        return changed
    }

    private func move(_ units: Int) async -> Bool {
        let before = snapshot()
        proxy()?.adjustTextPosition(byCharacterOffset: units)
        return await settle(from: before)
    }

    // MARK: Field mirror

    struct Walk {
        var text = ""
        var origOffset = 0
        var ok = false
    }

    /// Reads the whole field by walking to its start and then to its end in window-sized steps, then puts
    /// the cursor back. Logs one `walk` line.
    @discardableResult
    func walk(label: String) async -> Walk {
        proxyWaits = []; proxyTimeouts = 0
        let t0 = Date()
        let s0 = snapshot()
        var moved = 0              // UTF-16 units moved back from the original position
        var backSteps = 0, fwdSteps = 0
        var beforeSizes: [Int] = [], afterSizes: [Int] = []
        var notes: [String] = []
        // Phase 1: to the start.
        var guardCount = 0
        while guardCount < 4000 {
            guardCount += 1
            let snap = snapshot()
            beforeSizes.append(snap.before.utf16.count)
            if snap.before.isEmpty {
                let ok = await move(-1)
                let after = snapshot()
                if !ok || (after.before.isEmpty && after.after == snap.after) { break }
                moved += 1; backSteps += 1
                continue
            }
            let k = snap.before.utf16.count
            _ = await move(-k)
            moved += k; backSteps += 1
        }
        if guardCount >= 4000 { notes.append("back-walk guard hit") }
        // Phase 2: forward to the end, stitching the windows after the cursor.
        var text = ""
        guardCount = 0
        var stitchMismatch = 0
        var rereads = 0
        while guardCount < 4000 {
            guardCount += 1
            var snap = snapshot()
            // Re-read while the window before the cursor disagrees with the text so far (a stale pair).
            var tries = 0
            while tries < 10 {
                try? await Task.sleep(for: .milliseconds(15))
                let again = snapshot()
                // Accept only two consecutive identical reads that also stitch onto the text so far.
                if again == snap, snap.before.isEmpty || text.hasSuffix(snap.before) { break }
                snap = again; tries += 1; rereads += 1
            }
            afterSizes.append(snap.after.utf16.count)
            // Consistency: what the field says is before the cursor must be the end of what we have.
            let b = snap.before
            if !b.isEmpty, !text.hasSuffix(b) { stitchMismatch += 1 }
            if snap.after.isEmpty {
                let ok = await move(1)
                let after = snapshot()
                if !ok || (after.after.isEmpty && after.before == snap.before) { break }
                text += String(after.before.suffix(1)); fwdSteps += 1
                continue
            }
            text += snap.after
            _ = await move(snap.after.utf16.count)
            fwdSteps += 1
        }
        let total = text.utf16.count
        // Phase 3: back to where the cursor was.
        // `moved` units went back from the original position to the start, so the original is at `moved`.
        let origOffset = moved
        let back = total - origOffset
        if back > 0 { _ = await move(-back) }
        let sEnd = snapshot()
        let utf16 = Array(text.utf16)
        func slice(_ a: Int, _ b: Int) -> String { String(decoding: utf16[max(0, a)..<min(utf16.count, max(a, b))], as: UTF16.self) }
        let beforeOK = slice(origOffset - s0.before.utf16.count, origOffset) == s0.before
        let afterOK = slice(origOffset, origOffset + s0.after.utf16.count) == s0.after
        let cursorExact = sEnd.before == s0.before && sEnd.after == s0.after
        let sel0 = s0.selected ?? "", sel1 = sEnd.selected ?? ""
        let elapsed = Date().timeIntervalSince(t0) * 1000
        func stat(_ a: [Int]) -> [String: Any] {
            a.isEmpty ? [:] : ["min": a.min()!, "max": a.max()!, "avg": a.reduce(0, +) / a.count, "first": Array(a.prefix(6))]
        }
        log([
            "event": "walk", "label": label, "ms": Int(elapsed), "len": total, "hash": stableHash(text),
            "stepsBack": backSteps, "stepsFwd": fwdSteps, "origOffset": origOffset,
            "beforeWindows": stat(beforeSizes), "afterWindows": stat(afterSizes),
            "initialBefore": s0.before.utf16.count, "initialAfter": s0.after.utf16.count,
            "stitchMismatch": stitchMismatch, "rereads": rereads, "origMatchesInitialWindows": beforeOK && afterOK,
            "cursorExact": cursorExact, "selBefore": sel0.utf16.count, "selAfter": sel1.utf16.count,
            "selectionPreserved": sel0 == sel1,
            "settleAvgMs": proxyWaits.isEmpty ? 0 : Int(proxyWaits.reduce(0, +) / Double(proxyWaits.count)),
            "settleMaxMs": Int(proxyWaits.max() ?? 0), "settleTimeouts": proxyTimeouts, "notes": notes,
        ])
        return Walk(text: text, origOffset: origOffset, ok: beforeOK && afterOK && cursorExact && stitchMismatch == 0)
    }

    private func stableHash(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }

    // MARK: Replay

    private static let baseSentence = "I think there going to meet us at the station. We should probably leave early because the traffic is bad today. Then we can get coffee"
    private static let revisions: [(String, String, String)] = [
        ("flip word mid-text", "there going", "they're going"),
        ("flip word in earlier sentence", "I think", "I thought"),
        ("insert word", "leave early", "leave very early"),
        ("remove word", "traffic is bad today", "traffic is today"),
        ("punctuation comma", "early because", "early, because"),
        ("punctuation period to bang", "station.", "station!"),
        ("append period at end", "get coffee", "get coffee."),
    ]

    private func filler(_ chars: Int) -> String {
        let sentences = [
            "Alpha marker sits at the very start of this field.",
            "The quick brown fox jumps over the lazy dog near the caf\u{e9}.",
            "We met at nine, then walked along the harbour for an hour \u{1F600}.",
            "Numbers like 42 and 3.14 appear here as well.",
            "Short one.",
            "Sailing south in autumn is rarely a mistake, said the old skipper.",
        ]
        var out = ""
        var i = 0
        while out.count < chars {
            out += sentences[i % sentences.count]
            i += 1
            out += (i % 9 == 0) ? "\n\n" : " "
        }
        return out
    }

    private func type(_ text: String, chunk: Int, delayMs: Int) async {
        var rest = Substring(text)
        while !rest.isEmpty {
            let piece = rest.prefix(chunk)
            rest = rest.dropFirst(chunk)
            proxy()?.insertText(String(piece))
            if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
        }
    }

    private func execute(_ ops: [ShadowOp], settleEach: Bool, maxMove: Int) async {
        for op in ops {
            switch op {
            case .move(let units):
                var left = units
                while left != 0 {
                    let step = max(-maxMove, min(maxMove, left))
                    if settleEach { _ = await move(step) } else { proxy()?.adjustTextPosition(byCharacterOffset: step) }
                    left -= step
                }
            case .deleteBackward(let n):
                for _ in 0..<n { proxy()?.deleteBackward() }
                if settleEach { try? await Task.sleep(for: .milliseconds(30)) }
            case .insert(let s):
                proxy()?.insertText(s)
                if settleEach { try? await Task.sleep(for: .milliseconds(30)) }
            }
        }
    }

    private func firstDiff(_ a: String, _ b: String) -> [String: Any] {
        let x = Array(a.utf16), y = Array(b.utf16)
        var i = 0
        while i < x.count, i < y.count, x[i] == y[i] { i += 1 }
        func win(_ u: [UInt16]) -> String { String(decoding: u[max(0, i - 15)..<min(u.count, i + 25)], as: UTF16.self) }
        return ["index": i, "expectedLen": x.count, "actualLen": y.count, "expectedAround": win(x), "actualAround": win(y)]
    }

    /// Types a sentence (after optional filler), then applies revisions one by one, re-walking after each to
    /// compare the field with the shadow; then undoes them all back-to-back without walking (drift check).
    private func replay(_ cmd: [String: Any]) async {
        let fill = cmd["fill"] as? Int ?? 0
        let cursorMode = cmd["cursor"] as? String ?? "end"
        let settleEach = (cmd["pace"] as? String ?? "none") == "settle"
        let maxMove = cmd["maxMove"] as? Int ?? 100_000
        let initial = await walk(label: "replay-initial")
        // Put the cursor at the end of existing text, then type.
        let toEnd = initial.text.utf16.count - initial.origOffset
        if toEnd > 0 { _ = await move(toEnd) }
        var expected = initial.text
        if fill > 0 {
            let f = filler(fill)
            await type(f, chunk: 200, delayMs: 20)
            expected += f
        }
        let tTyping = Date()
        await type(Self.baseSentence, chunk: 5, delayMs: 15) // word-ish chunks like streamed STT
        expected += Self.baseSentence
        log(["event": "typed", "typingMs": Int(Date().timeIntervalSince(tTyping) * 1000), "len": expected.utf16.count])
        var cur = await walk(label: "replay-after-typing")
        log(["event": "verify", "step": "typed", "equal": cur.text == expected, "diff": cur.text == expected ? [:] : firstDiff(expected, cur.text)])
        var shadow = cur.text
        var cursor = cur.origOffset
        if cursorMode == "mid", let r = shadow.range(of: "probably") {
            let target = shadow[..<r.upperBound].utf16.count
            _ = await move(target - cursor)
            cursor = target
            cur = await walk(label: "replay-cursor-mid")
            cursor = cur.origOffset
            shadow = cur.text
        }
        var pass = 0, fail = 0
        var applied: [(String, String, String)] = []
        var extra = fill > 0 ? [("flip word at far start", "Alpha marker", "Alpha Marker!")] : []
        extra += Self.revisions
        for (name, find, repl) in extra {
            guard let r = shadow.range(of: find) else { log(["event": "skip", "step": name, "reason": "find missing"]); continue }
            let target = shadow.replacingCharacters(in: r, with: repl)
            let t0 = Date()
            let plan = ShadowEditPlanner.plan(shadow: shadow, cursor: cursor, target: target)
            let sim = ShadowEditPlanner.simulate(ops: plan.ops, shadow: shadow, cursor: cursor)
            await execute(plan.ops, settleEach: settleEach, maxMove: maxMove)
            let applyMs = Int(Date().timeIntervalSince(t0) * 1000)
            // Let the host catch up before reading.
            try? await Task.sleep(for: .milliseconds(150))
            let w = await walk(label: "replay-verify-\(name)")
            let textOK = w.text == target, cursorOK = w.origOffset == plan.cursor
            if textOK && cursorOK { pass += 1 } else { fail += 1 }
            log(["event": "verify", "step": name, "textEqual": textOK, "cursorEqual": cursorOK, "expectedCursor": plan.cursor,
                 "actualCursor": w.origOffset, "simulatorAgrees": sim.text == target && sim.cursor == plan.cursor,
                 "opCount": plan.ops.count, "ops": describe(plan.ops), "applyMs": applyMs,
                 "diff": textOK ? [:] : firstDiff(target, w.text)])
            applied.append((name, find, repl))
            shadow = w.text; cursor = w.origOffset // re-baseline on what the field really holds
        }
        // Drift check: undo everything back-to-back on the tracked shadow, with no reads in between.
        var tracked = shadow, trackedCursor = cursor
        let ops0 = Date()
        var total = 0
        for (name, find, repl) in applied.reversed() {
            guard let r = tracked.range(of: repl) else { continue }
            let target = tracked.replacingCharacters(in: r, with: find)
            let plan = ShadowEditPlanner.plan(shadow: tracked, cursor: trackedCursor, target: target)
            await execute(plan.ops, settleEach: settleEach, maxMove: maxMove)
            tracked = target; trackedCursor = plan.cursor; total += plan.ops.count
            _ = name
        }
        let driftMs = Int(Date().timeIntervalSince(ops0) * 1000)
        try? await Task.sleep(for: .milliseconds(200))
        let fin = await walk(label: "replay-after-undo-all")
        log(["event": "verify", "step": "undo-all-no-reads", "textEqual": fin.text == tracked, "cursorEqual": fin.origOffset == trackedCursor,
             "applyMs": driftMs, "opCount": total, "diff": fin.text == tracked ? [:] : firstDiff(tracked, fin.text)])
        log(["event": "summary", "pass": pass, "fail": fail, "fill": fill, "cursor": cursorMode, "pace": settleEach ? "settle" : "none"])
    }

    private func describe(_ ops: [ShadowOp]) -> [String] {
        ops.map {
            switch $0 {
            case .move(let n): "move(\(n))"
            case .deleteBackward(let n): "del(\(n))"
            case .insert(let s): "ins(\(s.count > 20 ? String(s.prefix(20)) + "..." : s))"
            }
        }
    }
}
#endif
