#if LEGATO_INTERNAL
import Foundation
import LegatoAppServices
import LegatoAudio
import LegatoClaude
import LegatoCore
import LegatoMeetings
import LegatoSoniox

/// Internal-only offline acceptance. Both provider factories are replaced unconditionally, including
/// when exercising the physical microphone. Every fixture has its own files and summary defaults.
enum IOSMeetingFixtureConfiguration {
    static let name: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--meetings-fixture") else { return nil }
        guard args.indices.contains(index + 1) else { preconditionFailure("Missing offline meeting fixture name") }
        let name = args[index + 1]
        guard !name.isEmpty, name.count <= 64, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { preconditionFailure("Invalid offline meeting fixture name") }
        return name
    }()
    static var applicationRoot: URL? { name.map { URL.applicationSupportDirectory.appending(path: "MeetingFixtures/\($0)", directoryHint: .isDirectory) } }
    static var defaults: UserDefaults? { name.flatMap { UserDefaults(suiteName: "de.gruenwald.legato.meeting-fixture.\($0)") } }
}

@MainActor
final class IOSMeetingFixture {
    static let current: IOSMeetingFixture? = IOSMeetingFixtureConfiguration.name.map {
        IOSMeetingFixture(name: $0, realMicrophone: ProcessInfo.processInfo.arguments.contains("--meetings-real-microphone"))
    }
    let applicationRoot: URL
    let defaults: UserDefaults
    let realMicrophone: Bool
    let services: MeetingServices
    private init(name: String, realMicrophone: Bool) {
        self.realMicrophone = realMicrophone
        applicationRoot = URL.applicationSupportDirectory.appending(path: "MeetingFixtures/\(name)", directoryHint: .isDirectory)
        defaults = UserDefaults(suiteName: "de.gruenwald.legato.meeting-fixture.\(name)")!
        services = MeetingServices(store: MeetingStore(root: applicationRoot.appending(path: "Meetings")),
            settings: MeetingSettings(defaults: defaults), sonioxKey: { "offline-fixture" },
            claudeKeys: InMemoryAPIKeyStore(apiKey: "offline-fixture"), claudeBackend: FixtureSummary(),
            personalPrompt: { "" }, makeSocket: { FixtureMeetingSocket() })
    }
    func microphone() -> any AudioSource { realMicrophone ? AutomaticInputSource() : FixtureMicrophone() }
}

private struct FixtureSummary: LLMBackend {
    let id = "offline-fixture"
    let maxPromptCharacters: Int? = 600_000
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String {
        if instructions == MeetingTitle.instructions { return "Offline planning meeting" }
        return "## Summary\n\nThe team discussed the launch plan.\n\n## Decisions\n\nPrepare a prototype before Friday.\n\n## Action items\n\n- Speaker 1 will prepare the prototype.\n- Speaker 2 will review it.\n\n_Offline acceptance fixture; this text is scripted._"
    }
}

private actor FixtureMicrophone: AudioSource {
    private var task: Task<Void, Never>?
    private var sink: AsyncStream<AudioChunk>.Continuation?
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        let pair = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(8))
        sink = pair.continuation
        task = Task {
            var offset = 0
            while !Task.isCancelled {
                let samples = (0..<1600).map { index in Float(sin(Double(offset + index) * 2 * .pi * 220 / 16000) * 0.02) }
                pair.continuation.yield(AudioChunk(samples: samples, format: format))
                offset += samples.count
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return pair.stream
    }
    func route() async throws -> AsyncStream<AudioChunk> { throw MicSourceError.notArmed }
    func detach() async {}
    func stop() async { task?.cancel(); task = nil; sink?.finish(); sink = nil }
}

private actor FixtureMeetingSocket: SonioxSocket {
    private var inbox: [SonioxFrame] = []
    private var waiter: CheckedContinuation<SonioxFrame, any Error>?
    private var closed = false
    private var bytes = 0
    private var delivered = 0
    func connect(request: URLRequest) async throws {}
    func send(_ frame: SonioxFrame) async throws {
        guard !closed else { throw SonioxError.cancelled }
        if frame == .text(#"{"type":"finalize"}"#) { feed(#"{"tokens":[{"text":"<fin>","is_final":true}]}"#) }
        if frame == .text("") { feed(#"{"finished":true}"#) }
        if case .binary(let data) = frame {
            bytes += data.count
            let script = [" Let's discuss the launch plan.", " We should prepare a prototype before Friday.", " I will prepare it and you can review it.", " Agreed. Let's meet again next week."]
            if delivered < script.count, bytes >= (delivered + 1) * 64000 {
                let json: [String: Any] = ["tokens": [["text": script[delivered], "is_final": true,
                    "start_ms": delivered * 2000, "end_ms": (delivered + 1) * 2000, "speaker": String(delivered % 2 + 1)]]]
                let data = try JSONSerialization.data(withJSONObject: json)
                feed(String(decoding: data, as: UTF8.self)); delivered += 1
            }
        }
    }
    func receive() async throws -> SonioxFrame {
        if !inbox.isEmpty { return inbox.removeFirst() }
        guard !closed else { throw SonioxError.cancelled }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() async { closed = true; waiter?.resume(throwing: SonioxError.cancelled); waiter = nil }
    private func feed(_ text: String) {
        if let waiter { self.waiter = nil; waiter.resume(returning: .text(text)) }
        else { inbox.append(.text(text)) }
    }
}
#endif
