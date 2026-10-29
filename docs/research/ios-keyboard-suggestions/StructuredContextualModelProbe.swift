import Foundation
import FoundationModels

@Generable
struct Suggestions {
    var first: String
    var second: String
    var third: String
}

struct Fixture {
    let id: String
    let context: String
    let prefix: String
    let language: String
}

@main
struct Probe {
    static func main() async {
        let fixtures = [
            Fixture(id: "en-port-sailing", context: "The sailor repaired the port ", prefix: "", language: "English"),
            Fixture(id: "en-port-software", context: "The developer configured the port ", prefix: "", language: "English"),
            Fixture(id: "en-ba-bakery", context: "At the bakery, she mixed flour and eggs to make a ba", prefix: "ba", language: "English"),
            Fixture(id: "en-ba-cave", context: "In the cave, she heard wings and spotted a ba", prefix: "ba", language: "English"),
            Fixture(id: "de-mo-engine", context: "Die Werkstatt repariert das Segelboot und bestellt einen neuen Mo", prefix: "Mo", language: "German"),
            Fixture(id: "de-mo-moon", context: "Die Astronomin richtet ihr Teleskop aus und beobachtet einen neuen Mo", prefix: "Mo", language: "German")
        ]
        let index = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 0
        let fixture = fixtures[index]
        let start = ContinuousClock.now
        var row: [String: Any] = ["id": fixture.id, "context": fixture.context, "prefix": fixture.prefix,
                                  "language": fixture.language, "index": index,
                                  "model": "SystemLanguageModel.default", "prewarm": false]
        do {
            let model = SystemLanguageModel.default
            guard model.isAvailable else {
                row["outcome"] = "unavailable"
                emit(row)
                return
            }
            let session = LanguageModelSession(model: model, instructions: "You suggest words for a keyboard. Generate three distinct single words in first, second, and third. Use earlier sentence meaning. For a nonempty partial-word prefix, return the complete word including that prefix, and every word must start with that prefix (case-insensitive). For an empty prefix return likely next words. Match the specified language. These are optional tappable words, never an automatic edit.")
            let response = try await session.respond(
                to: "Language: \(fixture.language)\nText before cursor: \(fixture.context)\nPartial-word prefix: \(fixture.prefix.isEmpty ? "(empty)" : fixture.prefix)",
                generating: Suggestions.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 128))
            row["structured"] = true
            let words = [response.content.first, response.content.second, response.content.third]
                let valid = words.filter { word in
                    !word.isEmpty && word.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
                        && word.lowercased().hasPrefix(fixture.prefix.lowercased())
                }
                row["words"] = words
                row["validatedWords"] = valid
                row["valid"] = words.count == 3 && valid.count == 3 && Set(words.map { $0.lowercased() }).count == 3
                row["outcome"] = "completed"
        } catch {
            row["outcome"] = "error"
            row["error"] = String(describing: error)
        }
        let elapsed = start.duration(to: .now).components
        row["milliseconds"] = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        emit(row)
    }

    static func emit(_ row: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }
}
