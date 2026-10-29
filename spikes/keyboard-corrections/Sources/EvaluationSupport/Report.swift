import Foundation
public func pathArg(_ key: String) -> String {
    guard let i = CommandLine.arguments.firstIndex(of: key), i + 1 < CommandLine.arguments.count else { fatalError("Missing argument " + key) }
    return CommandLine.arguments[i+1]
}
public func jsonWrite(_ value: Any, path: String) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]).write(to: URL(fileURLWithPath: path))
}
public final class Records {
    private let handle: FileHandle
    public private(set) var failures = 0
    public private(set) var count = 0
    public init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    }
    public func emit(_ value: [String: Any]) throws {
        var v = value; v["evidence"] = "harness"
        let data = try JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])
        try handle.write(contentsOf: data); try handle.write(contentsOf: Data([10])); try handle.synchronize()
        count += 1
        if let checks = v["assertions"] as? [String: Bool] { failures += checks.values.filter { !$0 }.count }
    }
}
public func latencySummary(_ times: [Double]) -> [String: Any] {
    guard !times.isEmpty else { return ["n": 0] }
    let s = times.sorted()
    return ["n": s.count, "medianMs": s[(s.count-1)/2], "p95Ms": s[min(s.count-1, Int(ceil(Double(s.count)*0.95))-1)]]
}
public func byteEqual(_ a: String, _ b: String) -> Bool { Array(a.utf8) == Array(b.utf8) }
public struct ContiguousPatch: Sendable {
    public let location: Int
    public let removed: String
    public let inserted: String
    public let suffix: String
    public init(old: String, new: String) {
        let a = Array(old), b = Array(new)
        // Byte equality at Character boundaries preserves decomposed representations.
        var prefix = 0
        while prefix < min(a.count,b.count), byteEqual(String(a[prefix]), String(b[prefix])) { prefix += 1 }
        var tail = 0
        while tail < min(a.count-prefix,b.count-prefix), byteEqual(String(a[a.count-1-tail]), String(b[b.count-1-tail])) { tail += 1 }
        location = prefix
        removed = String(a[prefix..<(a.count-tail)])
        inserted = String(b[prefix..<(b.count-tail)])
        suffix = String(a[(a.count-tail)...])
    }
    public func apply(to text: String) -> String? {
        let a = Array(text)
        guard location >= 0, location + removed.count <= a.count,
              byteEqual(String(a[location..<(location+removed.count)]), removed) else { return nil }
        return String(a[..<location]) + inserted + String(a[(location+removed.count)...])
    }
}
