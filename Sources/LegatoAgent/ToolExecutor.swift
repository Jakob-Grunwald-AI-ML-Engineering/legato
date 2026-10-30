import Foundation
import LegatoClaude
import LegatoRoom
import LegatoComposerDoc

public struct ToolResult: Sendable {
    public let content: String
    public let isError: Bool
    public var mode: ComposerMode? = nil
}
public struct ToolExecutor: Sendable {
    public let room: Room
    public init(room: Room) { self.room = room }
    public func execute(name: String, input: JSONValue, groupID: String, live: Bool, phase: WritingPhase = .pause) async -> ToolResult {
        if phase == .quick, ["replace_lines", "insert_lines", "delete_lines", "move_lines", "set_kind"].contains(name) {
            return ToolResult(content: "Deferred: this quick pass only makes local corrections. Leave broader changes for the quiet-pause or final turn; do not retry them now.", isError: true)
        }
        do {
            let snapshot = await room.documentSnapshot
            func string(_ key: String) throws -> String { guard case .string(let s) = input[key] else { throw DocumentError.invalidOperation }; return s }
            func optional(_ key: String) -> String? { if case .string(let s) = input[key] { return s }; return nil }
            func ids() throws -> [String] {
                guard let a = snapshot.lines.firstIndex(where: { $0.id == optional("from") }),
                      let b = snapshot.lines.firstIndex(where: { $0.id == optional("to") }), a <= b else { throw DocumentError.invalidOperation }
                return snapshot.lines[a...b].map(\.id)
            }
            func versions() throws -> [String: Int] {
                guard let v = input["versions"] else { throw DocumentError.invalidOperation }
                if let map = try? v.decode([String: Int].self) { return map }
                struct Version: Decodable { let line: String; let version: Int }
                let pairs = try v.decode([Version].self)
                guard Set(pairs.map(\.line)).count == pairs.count else { throw DocumentError.invalidOperation }
                return Dictionary(uniqueKeysWithValues: pairs.map { ($0.line, $0.version) })
            }
            func newLines() throws -> [Line] {
                guard let v = input["lines"] else { throw DocumentError.invalidOperation }
                let texts = try v.decode([String].self)
                return texts.map { Line(words: DocPresenter.strip($0).split(whereSeparator: \.isWhitespace).map { Word(text: String($0)) }) }
            }
            var op: DocOp, observed: [String: Int] = [:]
            switch name {
            case "view":
                let selected: [Line]
                if optional("from") != nil || optional("to") != nil {
                    let from = optional("from") ?? snapshot.lines.first?.id
                    let to = optional("to") ?? snapshot.lines.last?.id
                    guard let a = snapshot.lines.firstIndex(where: { $0.id == from }), let b = snapshot.lines.firstIndex(where: { $0.id == to }), a <= b else { throw DocumentError.invalidOperation }
                    selected = Array(snapshot.lines[a...b])
                } else { selected = snapshot.lines }
                return ToolResult(content: DocPresenter.present(.init(revision: snapshot.revision, lines: selected)), isError: false)
            case "replace_lines": op = .replaceLines(ids: try ids(), lines: try newLines()); observed = try versions()
            case "insert_lines": op = .insertLines(after: optional("after"), lines: try newLines())
            case "delete_lines": op = .deleteLines(ids: try ids()); observed = try versions()
            case "replace_in_line":
                let id = try string("line"); guard case .number(let v) = input["version"], v.isFinite, v.rounded() == v, v >= 0, v < Double(Int.max) else { throw DocumentError.invalidOperation }
                op = .replaceInLine(lineID: id, old: DocPresenter.strip(try string("old")), new: DocPresenter.strip(try string("new"))); observed = [id: Int(v)]
            case "move_lines": op = .moveLines(ids: try ids(), after: optional("after")); observed = try versions()
            case "set_kind":
                guard let v = input["lines"], let kind = LineKind(rawValue: try string("kind")) else { throw DocumentError.invalidOperation }
                op = .setKind(ids: try v.decode([String].self), kind: kind); observed = try versions()
            case "load_writing_guidance":
                guard let mode = ComposerMode(rawValue: try string("mode")) else { throw DocumentError.invalidOperation }
                return ToolResult(content: try PromptLayers.writingGuidance(for: mode), isError: false)
            case "set_mode":
                guard let mode = ComposerMode(rawValue: try string("mode")) else { throw DocumentError.invalidOperation }
                _ = try await room.publish(channel: .userIntent, participant: live ? .liveAgent : .restructureAgent,
                    payload: .object(["event": .string("mode.changed"), "mode": .string(mode.rawValue)]))
                return ToolResult(content: "Mode changed", isError: false, mode: mode)
            case "note": return ToolResult(content: try string("text"), isError: false)
            default: throw DocumentError.invalidOperation
            }
            try Task.checkCancellation()
            let txn = try await room.applyDocument([op], origin: .agent, versions: observed, groupID: groupID)
            return ToolResult(content: "Applied transaction \(txn.id)\n" + DocPresenter.present(await room.documentSnapshot), isError: false)
        } catch { return ToolResult(content: "\(error). Call view to refresh line ids and versions before retrying.", isError: true) }
    }
    public static func schemas(live: Bool, mode: ComposerMode = .message) -> [ToolSchema] {
        typealias S = ToolSchema.Schema
        let str = S(type: "string"), array = S(type: "array", items: S(type: "string"))
        // Strict JSON Schema forbids open dictionaries. Represent the version map as line/version pairs.
        let versions = S(type: "array", items: S(type: "object", properties: ["line": str, "version": S(type: "integer")], required: ["line", "version"], additionalProperties: false))
        func tool(_ name: String, _ fields: [String: S], _ required: [String]? = nil) -> ToolSchema {
            ToolSchema(name: name, description: "\(name): use observed line IDs and versions. On error view and retry.", properties: fields, required: required ?? fields.keys.sorted())
        }
        var tools = [tool("view", ["from": str, "to": str], []),
            tool("replace_lines", ["from": str,"to": str,"lines": array,"versions": versions]),
            tool("insert_lines", ["after": str,"lines": array], ["lines"]),
            tool("delete_lines", ["from": str,"to": str,"versions": versions]),
            tool("replace_in_line", ["line": str,"old": str,"new": str,"version": S(type: "integer")]),
            tool("move_lines", ["from": str,"to": str,"after": str,"versions": versions], ["from","to","versions"]),
            tool("set_kind", ["lines": array,"kind": str,"versions": versions]),
            tool("set_mode", ["mode": str]), tool("note", ["text": str])]
        if mode == .auto {
            // Specialization loads context without changing the Auto system prefix or UI mode.
            tools.removeAll { $0.name == "set_mode" }
            tools.append(ToolSchema(name: "load_writing_guidance",
                description: "Load the existing writing skill for the intended format before drafting or revising in Auto. Returns guidance as context; does not edit the document or change mode.",
                properties: ["mode": S(type: "string", enumValues: ["message", "email", "prompt", "note"])], required: ["mode"]))
        }
        return tools
    }
}
