// legato-voice-replay: replays kept voice recordings (exported from Settings) through the production background-voice
// filter and reports own-voice words admitted and background words admitted. See scripts/dev/voice-replay.md.
import Foundation
import LegatoClaude
import LegatoSoniox
import LegatoVoiceIdentity

let usage = """
Usage: legato-voice-replay [--transcribe] [--profiles FILE] [--exclude-own-profile] [--json] [--models DIR] PATH...

PATH is an exported recordings zip, a folder of recordings, or one recording folder (recording.wav + recording.json).
A zip is unpacked once next to itself, so cached tokens persist.

  --transcribe            Get Soniox tokens for recordings without tokens.json (a paid live call, using the
                          Soniox key the app saved, or SONIOX_API_KEY). Tokens are cached next to each recording.
  --profiles FILE         The profile set to match against. Default: profiles.json in the export, otherwise the
                          Mac app's saved voice.
  --exclude-own-profile   Leave out the profile computed from the recording being replayed.
  --json                  Print the results as JSON.
  --models DIR            Where the pinned voice model is kept (default ~/Library/Caches/legato-voice-replay).
"""

struct Failure: Error, CustomStringConvertible { let description: String }

struct Options {
    var paths: [String] = []
    var transcribe = false
    var profiles: String?
    var excludeOwn = false
    var json = false
    var models: String?
    init(_ arguments: [String]) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--transcribe": transcribe = true
            case "--exclude-own-profile": excludeOwn = true
            case "--json": json = true
            case "--profiles": guard let value = iterator.next() else { throw Failure(description: usage) }; profiles = value
            case "--models": guard let value = iterator.next() else { throw Failure(description: usage) }; models = value
            case "-h", "--help": throw Failure(description: usage)
            default:
                if argument.hasPrefix("-") { throw Failure(description: "Unknown option \(argument).\n\n\(usage)") }
                paths.append(argument)
            }
        }
        if paths.isEmpty { throw Failure(description: usage) }
    }
}

struct Recording {
    let folder: URL
    let sidecar: VoiceRecordingSidecar
    var tokensURL: URL { folder.appendingPathComponent(VoiceRecordingStore.tokensName) }
}

struct Row: Codable {
    let recording: String
    let setting: String
    let route: String
    let score: VoiceReplayScore
}

/// A zip is unpacked beside itself (once); folders are searched for recording sidecars.
func inputFolders(_ paths: [String]) throws -> [URL] {
    try paths.map { path in
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard url.pathExtension.lowercased() == "zip" else { return url }
        let destination = url.deletingPathExtension()
        if !FileManager.default.fileExists(atPath: destination.path) {
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", url.path, destination.path]
            try ditto.run(); ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw Failure(description: "Could not unpack \(url.path).") }
        }
        return destination
    }
}

func recordings(in folders: [URL]) -> [Recording] {
    var found: [Recording] = []
    for folder in folders {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        var candidates = [folder.appendingPathComponent(VoiceRecordingStore.sidecarName)]
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == VoiceRecordingStore.sidecarName { candidates.append(url.standardizedFileURL) }
        }
        for url in Set(candidates.map(\.standardizedFileURL)) {
            guard let data = try? Data(contentsOf: url),
                  let sidecar = try? VoiceJSON.decoder.decode(VoiceRecordingSidecar.self, from: data) else { continue }
            found.append(Recording(folder: url.deletingLastPathComponent(), sidecar: sidecar))
        }
    }
    return found.sorted { $0.sidecar.date < $1.sidecar.date }
}

/// `--profiles`, else the export's profiles.json, else the Mac app's saved voice (read only, never migrated on disk).
func loadProfiles(explicit: String?, folders: [URL]) throws -> (VoiceProfileSet, URL) {
    func read(_ url: URL) -> VoiceProfileSet? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if url.lastPathComponent == "profile.json" { return VoiceProfileSet.migrating(legacy: data, date: Date()) }
        return try? VoiceJSON.decoder.decode(VoiceProfileSet.self, from: data)
    }
    if let explicit {
        let url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        guard let set = read(url) else { throw Failure(description: "Could not read profiles from \(url.path).") }
        return (set, url)
    }
    for folder in folders {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == VoiceIdentityService.profilesName, let set = read(url) { return (set, url) }
        }
    }
    let mac = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Legato/VoiceIdentity/de.gruenwald.legato.mac", isDirectory: true)
    for name in [VoiceIdentityService.profilesName, "profile.json"] {
        let url = mac.appendingPathComponent(name)
        if let set = read(url) { return (set, url) }
    }
    throw Failure(description: "No profiles: export with profiles.json, pass --profiles, or set up the voice in the Mac app.")
}

/// The Soniox key the apps save (Keychain service `de.gruenwald.legato.soniox`); SONIOX_API_KEY when this unsigned
/// tool cannot read the app's Keychain item.
func sonioxKey() throws -> String {
    if let key = try? KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey(), !key.isEmpty { return key }
    if let key = ProcessInfo.processInfo.environment["SONIOX_API_KEY"], !key.isEmpty { return key }
    throw Failure(description: "No Soniox key: this tool could not read the app's Keychain item. Set SONIOX_API_KEY for this run.")
}

actor SentAudio {
    var samples = 0
    func add(_ count: Int) { samples += count }
}

/// One real-time stream at real-time pace, as dictation sends it. Each response records `t`, the seconds of audio
/// sent when it arrived, so a replay gives the filter exactly the audio it would have had live.
func transcribe(_ samples: [Float], apiKey: String) async throws -> VoiceFilterReplay.TokenCache {
    struct Response: Decodable { var tokens: [SonioxToken]?; var finished: Bool?; var error_code: Int?; var error_message: String? }
    let config = SonioxConfig()
    let start = try config.message()
    let model = (try? JSONSerialization.jsonObject(with: start) as? [String: Any])?["model"] as? String
    let socket = URLSessionSonioxSocket(), sent = SentAudio()
    try await socket.connect(request: config.request(apiKey: apiKey))
    try await socket.send(.text(String(decoding: start, as: UTF8.self)))
    let receiver = Task { () throws -> [VoiceFilterReplay.Response] in
        var responses: [VoiceFilterReplay.Response] = []
        while true {
            let frame = try await socket.receive()
            let data: Data = switch frame { case .text(let text): Data(text.utf8); case .binary(let bytes): bytes }
            let response = try JSONDecoder().decode(Response.self, from: data)
            if let code = response.error_code { throw Failure(description: "Soniox error \(code): \(response.error_message ?? "")") }
            responses.append(.init(t: Double(await sent.samples) / 16000, tokens: response.tokens ?? [], finished: response.finished))
            if response.finished == true { return responses }
        }
    }
    let chunk = 1920 // 120 ms
    var offset = 0
    while offset < samples.count {
        let end = min(samples.count, offset + chunk)
        var data = Data(capacity: (end - offset) * 2)
        for sample in samples[offset..<end] {
            let value = Int16((max(-1, min(1, sample)) * 32767).rounded())
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        try await socket.send(.binary(data))
        await sent.add(end - offset); offset = end
        try await Task.sleep(for: .milliseconds(120))
    }
    // An empty text frame ends the audio; Soniox then finalizes and reports finished.
    try await socket.send(.text(""))
    let watchdog = Task { try await Task.sleep(for: .seconds(60)); await socket.close() }
    defer { watchdog.cancel() }
    let responses = try await receiver.value
    await socket.close()
    return .init(model: model, responses: responses)
}

func percent(_ part: Int, _ whole: Int) -> String {
    whole == 0 ? "\(part)/0" : String(format: "%d/%d (%.1f%%)", part, whole, Double(part) * 100 / Double(whole))
}
func line(_ label: String, _ score: VoiceReplayScore) -> String {
    var text = "\(label): own voice admitted \(percent(score.ownAdmitted, score.ownWords)), background admitted \(percent(score.backgroundAdmitted, score.backgroundWords))"
    var notes: [String] = []
    if score.ownPartial > 0 { notes.append("\(score.ownPartial) own partly") }
    if score.backgroundPartial > 0 { notes.append("\(score.backgroundPartial) background partly") }
    if score.unlabelledWords > 0 { notes.append("\(score.unlabelledWords) unlabelled") }
    if !notes.isEmpty { text += " [" + notes.joined(separator: ", ") + "]" }
    return text
}

func main() async -> Int32 {
    do {
        let options = try Options(Array(CommandLine.arguments.dropFirst()))
        let folders = try inputFolders(options.paths)
        let found = recordings(in: folders)
        guard !found.isEmpty else { throw Failure(description: "No recordings (recording.json) found.") }
        let (profiles, profilesURL) = try loadProfiles(explicit: options.profiles, folders: folders)
        let modelsRoot = URL(fileURLWithPath: ((options.models ?? "~/Library/Caches/legato-voice-replay") as NSString).expandingTildeInPath, isDirectory: true)
        let service = VoiceIdentityService(root: modelsRoot)
        try await service.prepareModels()
        if !options.json { print("Profiles: \(profiles.profiles.count) from \(profilesURL.path)") }
        var rows: [Row] = [], skipped: [String] = []
        for recording in found {
            let name = recording.folder.lastPathComponent
            let audio = try VoiceWAV.decode(Data(contentsOf: recording.folder.appendingPathComponent(recording.sidecar.audioFile)))
            guard audio.sampleRate == 16000 else { skipped.append("\(name): not 16 kHz"); continue }
            let cache: VoiceFilterReplay.TokenCache
            if let data = try? Data(contentsOf: recording.tokensURL) {
                cache = try JSONDecoder().decode(VoiceFilterReplay.TokenCache.self, from: data)
            } else if options.transcribe {
                if !options.json { print("Transcribing \(name) (about \(Int(Double(audio.samples.count) / 16000)) s)…") }
                cache = try await transcribe(audio.samples, apiKey: try sonioxKey())
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(cache).write(to: recording.tokensURL, options: .atomic)
            } else { skipped.append("\(name): no tokens.json (run with --transcribe)"); continue }
            var set = profiles
            if options.excludeOwn { set.profiles.removeAll { $0.recordingID == recording.sidecar.id } }
            guard let matcher = try? await service.matcher(for: set) else { skipped.append("\(name): no profile left to match"); continue }
            let decisions = await VoiceFilterReplay.run(samples: audio.samples, responses: cache.responses, matcher: matcher)
            rows.append(Row(recording: name, setting: recording.sidecar.situationName, route: recording.sidecar.route.displayName,
                            score: VoiceReplayScore(decisions: decisions, intervals: recording.sidecar.intervals)))
        }
        var groups: [String: VoiceReplayScore] = [:]
        for row in rows { groups["\(row.setting) · \(row.route)", default: VoiceReplayScore()] = groups["\(row.setting) · \(row.route)", default: VoiceReplayScore()] + row.score }
        let total = rows.reduce(VoiceReplayScore()) { $0 + $1.score }
        if options.json {
            struct Report: Codable { let profiles: String; let recordings: [Row]; let groups: [String: VoiceReplayScore]; let total: VoiceReplayScore; let skipped: [String] }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(Report(profiles: profilesURL.path, recordings: rows, groups: groups, total: total, skipped: skipped)), as: UTF8.self))
        } else {
            print("\nPer recording")
            for row in rows { print("  " + line(row.recording, row.score)) }
            print("\nPer setting and microphone")
            for key in groups.keys.sorted() { print("  " + line(key, groups[key]!)) }
            print("\n" + line("Total", total))
            for note in skipped { print("Skipped \(note)") }
        }
        return rows.isEmpty ? 1 : 0
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        return error is Failure ? 2 : 1
    }
}

exit(await main())
