import Foundation

public enum PartialJSON {
    /// Only complete JSON string values are surfaced; incomplete escaped strings never become targets.
    public static func targets(in input: String) -> Set<String> {
        let pattern = #""(?:from|to|line|after)"\s*:\s*("(?:[^"\\]|\\.)*")"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(input.startIndex..., in: input)
        return Set(regex.matches(in: input, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: input) else { return nil }
            return try? JSONDecoder().decode(String.self, from: Data(input[r].utf8))
        })
    }
}
