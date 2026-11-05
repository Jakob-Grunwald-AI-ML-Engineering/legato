import Foundation
import LegatoMeetings
@testable import LegatoMeetingsCLI

/// Three meetings in a temp folder, written with `MeetingStore` the way the app writes them.
struct Fixture {
    let root: URL
    let kickoff: Meeting
    let weekly: Meeting
    let lunch: Meeting

    static func make() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legato-cli-\(UUID().uuidString)", isDirectory: true)
        let store = MeetingStore(root: root)
        var kickoff = Meeting(
            id: UUID(uuidString: "AAAA1111-0000-0000-0000-000000000001")!, title: "Kickoff", client: "Acme", project: "Website",
            tags: ["Planning", "design"], date: Date(timeIntervalSince1970: 1_700_000_000), duration: 125,
            speakers: ["P1": SpeakerInfo(name: "Alice", colorIndex: 0)], state: .finished)
        kickoff.locale = "en-US"
        let weekly = Meeting(
            id: UUID(uuidString: "AAAA2222-0000-0000-0000-000000000002")!, title: "Weekly", client: "acme", project: "App",
            tags: ["planning"], date: Date(timeIntervalSince1970: 1_700_100_000), duration: 60, state: .finished)
        let lunch = Meeting(
            id: UUID(uuidString: "BBBB3333-0000-0000-0000-000000000003")!, title: "Lunch chat", date: Date(timeIntervalSince1970: 1_700_200_000),
            duration: 30, state: .finished)
        for meeting in [kickoff, weekly, lunch] { try await store.create(meeting) }
        try await store.appendSegment(MeetingSegment(text: "We agreed on the Zürich launch date.", start: 3, end: 9, speaker: "P1"), to: kickoff.id)
        try await store.appendSegment(MeetingSegment(text: "Budget is fixed.", start: 12, end: 15, speaker: "P1"), to: kickoff.id)
        try await store.saveSummary("## Summary\n\nLaunch is set for March.", backendID: "claude", for: kickoff.id)
        try await store.saveNotes("Remember the invoice deadline.", for: weekly.id)
        try await store.appendSegment(MeetingSegment(text: "Pasta again.", start: 1, end: 2), to: lunch.id)
        return Fixture(root: root, kickoff: kickoff, weekly: weekly, lunch: lunch)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// Every file and folder under the root with its bytes: what must not change when meetings are only read.
    func snapshot() throws -> [String: Data?] {
        var found: [String: Data?] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
        while let url = walker?.nextObject() as? URL {
            let isDirectory = try url.resourceValues(forKeys: Set(keys)).isDirectory == true
            found[url.path] = isDirectory ? .some(nil) : .some(try Data(contentsOf: url))
        }
        return found
    }
}

/// Collects what a command prints.
final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var out = "", err = ""
    private var input: [String]

    init(input: [String] = []) { self.input = input }

    var stdout: String { lock.withLock { out } }
    var stderr: String { lock.withLock { err } }

    var console: Console {
        Console(
            out: { text in self.lock.withLock { self.out += text } },
            err: { text in self.lock.withLock { self.err += text } },
            readLine: { self.lock.withLock { self.input.isEmpty ? nil : self.input.removeFirst() } })
    }
}

func run(_ arguments: [String], input: [String] = []) async -> (status: Int32, stdout: String, stderr: String) {
    let capture = Capture(input: input)
    let status = await LegatoCLI.run(arguments, console: capture.console)
    return (status, capture.stdout, capture.stderr)
}
