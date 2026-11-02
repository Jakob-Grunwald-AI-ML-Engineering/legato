import Foundation
import LegatoRoom
import LegatoComposerDoc

/// Turns a writer tool call that is still streaming into the edit it would make so far, for a display-only
/// preview (`Room.setProvisional`). The authoritative `ToolExecutor.execute` still runs on the finished call.
///
/// Rules, all append-only per call:
/// - nothing previews until every id the call targets has arrived and the targets exist (and, once versions
///   arrive, match); `insert_lines`/`move_lines` also wait for `after`, whose absence means "at the top";
/// - text grows by whole words: a word is shown once whitespace or the closing quote follows it;
/// - `insert_lines` grows new lines after the anchor; `replace_in_line` swaps `old` for the words of `new`
///   so far (the rest of the line stays); `replace_lines` keeps the old lines until the first replacement
///   word exists, then shows exactly the replacement so far (the old tail is dropped at once, not word by word);
/// - `delete_lines`, `move_lines` and `set_kind` have no text and preview as soon as their fields are complete.
/// - words and lines are named from `seed`, so the final apply reuses the same ids and nothing re-animates.
public enum StreamingEdit {
    public static let tools: Set<String> = ["insert_lines", "replace_lines", "replace_in_line", "delete_lines", "move_lines", "set_kind"]

    public static func edit(name: String, tree: PartialJSONTree, base: DocumentSnapshot, seed: String,
                            phase: WritingPhase, allowedLineIDs: Set<String>?) -> Room.ProvisionalEdit? {
        guard tools.contains(name), tree.value != .null else { return nil }
        // The authoritative call would refuse these outright.
        if phase == .quick, name != "replace_in_line" { return nil }
        func ids() -> [String]? {
            guard tree.closed("from"), tree.closed("to"), let from = tree.string("from"), let to = tree.string("to"),
                  let a = base.lines.firstIndex(where: { $0.id == from }), let b = base.lines.firstIndex(where: { $0.id == to }), a <= b else { return nil }
            return base.lines[a...b].map(\.id)
        }
        /// Versions the model has stated (validated by the document) or, until they arrive, the current ones.
        func versions() -> [String: Int]? {
            let current = Dictionary(uniqueKeysWithValues: base.lines.map { ($0.id, $0.version) })
            guard tree.closed("versions"), let v = tree.value["versions"] else { return current }
            if let map = try? v.decode([String: Int].self) { return map }
            struct Pair: Decodable { let line: String; let version: Int }
            guard let pairs = try? v.decode([Pair].self), Set(pairs.map(\.line)).count == pairs.count else { return nil }
            return Dictionary(uniqueKeysWithValues: pairs.map { ($0.line, $0.version) })
        }
        func allowed(_ affected: [String]) -> Bool { allowedLineIDs.map { Set(affected).isSubset(of: $0) } ?? true }
        func newLines() -> [Line]? {
            guard let (items, closed) = tree.strings("lines") else { return nil }
            var lines: [Line] = [], flat = 0
            for (k, raw) in items.enumerated() {
                let words = DocPresenter.strip(raw).split(whereSeparator: \.isWhitespace).map { piece -> Word in
                    defer { flat += 1 }
                    return Word(id: "\(seed)-w\(flat)", text: String(piece))
                }
                // A line still being opened has no words yet: do not show an empty paragraph.
                if words.isEmpty, !closed, k == items.count - 1 { break }
                lines.append(Line(id: "L\(seed)-\(k)", words: words))
            }
            return lines
        }
        func make(_ op: DocOp, _ v: [String: Int]) -> Room.ProvisionalEdit { .init(op: op, versions: v, idSeed: seed) }

        switch name {
        case "insert_lines":
            let after = tree.string("after")
            guard tree.closed("after") || (tree.value["after"] == nil && (tree.closed("lines") || tree.complete)),
                  after.map({ id in base.lines.contains { $0.id == id } }) ?? true,
                  allowed(after.map { [$0] } ?? []), let lines = newLines(), !lines.isEmpty else { return nil }
            return make(.insertLines(after: after, lines: lines), [:])
        case "replace_lines":
            guard let target = ids(), allowed(target), let v = versions(), let lines = newLines(),
                  lines.contains(where: { !$0.words.isEmpty }) || tree.closed("lines") else { return nil }
            return make(.replaceLines(ids: target, lines: lines), v)
        case "delete_lines":
            guard let target = ids(), allowed(target), let v = versions() else { return nil }
            return make(.deleteLines(ids: target), v)
        case "move_lines":
            let after = tree.string("after")
            guard let target = ids(), allowed(target + (after.map { [$0] } ?? [])), let v = versions(),
                  tree.closed("after") || (tree.value["after"] == nil && tree.complete) else { return nil }
            return make(.moveLines(ids: target, after: after), v)
        case "set_kind":
            guard let (items, closed) = tree.strings("lines"), closed, tree.closed("kind"), let kind = tree.string("kind").flatMap(LineKind.init(rawValue:)),
                  allowed(items), let v = versions() else { return nil }
            return make(.setKind(ids: items, kind: kind), v)
        default: // replace_in_line
            guard tree.closed("line"), tree.closed("old"), let id = tree.string("line"), let old = tree.string("old"),
                  allowed([id]), let replacement = tree.words("new"), replacement.closed || !replacement.text.isEmpty else { return nil }
            var v = base.lines.first { $0.id == id }.map { [id: $0.version] } ?? [:]
            if tree.closed("version"), case .number(let n) = tree.value["version"], n.rounded() == n, n >= 0, n < Double(Int.max) { v = [id: Int(n)] }
            return make(.replaceInLine(lineID: id, old: DocPresenter.strip(old), new: DocPresenter.strip(replacement.text)), v)
        }
    }
}
