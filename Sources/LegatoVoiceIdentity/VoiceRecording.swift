import Foundation

/// A labelled stretch of a voice recording: the user reading `prompt`, or staying quiet.
public struct VoiceRecordingInterval: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case reading, quiet }
    public var kind: Kind
    public var startMs: Double
    public var endMs: Double
    public var prompt: String?
    public init(kind: Kind, startMs: Double, endMs: Double, prompt: String? = nil) {
        self.kind = kind; self.startMs = startMs; self.endMs = endMs; self.prompt = prompt
    }
    public func contains(ms: Double) -> Bool { ms >= startMs && ms < endMs }
}

/// The JSON next to a kept recording (`recording.json`): what, where and when it was recorded, and its intervals.
public struct VoiceRecordingSidecar: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case setup, setting }
    public var id: String
    public var kind: Kind
    public var situationID: String
    public var situationName: String
    public var route: VoiceInputRoute
    /// The hardware model, e.g. `iPhone17,1` or `Mac15,9`.
    public var device: String
    /// The operating system and its version, e.g. `iOS 26.2`.
    public var platform: String
    public var date: Date
    /// The language of the prompts (`en`, `de`).
    public var language: String
    public var sampleRate: Int
    public var audioFile: String
    public var intervals: [VoiceRecordingInterval]
    public init(id: String = UUID().uuidString.lowercased(), kind: Kind, situationID: String, situationName: String, route: VoiceInputRoute,
                device: String = VoiceRecordingSidecar.currentDevice, platform: String = VoiceRecordingSidecar.currentPlatform,
                date: Date = Date(), language: String, sampleRate: Int = 16000, audioFile: String = VoiceRecordingStore.audioName,
                intervals: [VoiceRecordingInterval]) {
        self.id = id; self.kind = kind; self.situationID = situationID; self.situationName = situationName; self.route = route
        self.device = device; self.platform = platform; self.date = date; self.language = language
        self.sampleRate = sampleRate; self.audioFile = audioFile; self.intervals = intervals
    }

    public static var currentDevice: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        let value = String(decoding: machine.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #if os(macOS)
        // `hw.machine` is the CPU architecture on a Mac; the model is `hw.model`.
        var modelSize = 0
        sysctlbyname("hw.model", nil, &modelSize, nil, 0)
        var model = [CChar](repeating: 0, count: max(modelSize, 1))
        sysctlbyname("hw.model", &model, &modelSize, nil, 0)
        let name = String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty ? value : name
        #else
        return value
        #endif
    }
    public static var currentPlatform: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let name = "iOS"
        #else
        let name = "macOS"
        #endif
        return "\(name) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

/// 16-bit PCM WAV, mono, for kept voice recordings.
public enum VoiceWAV {
    public enum WAVError: Error, Equatable { case unsupported }
    public static func encode(_ samples: [Float], sampleRate: Int = 16000) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for sample in samples {
            let clamped = max(-1, min(1, sample.isFinite ? sample : 0))
            append(Int16((clamped * 32767).rounded()))
        }
        return data
    }
    /// Samples and rate of a 16-bit PCM mono WAV (other chunks are skipped).
    public static func decode(_ data: Data) throws -> (samples: [Float], sampleRate: Int) {
        let bytes = [UInt8](data)
        func u32(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WAVE".utf8) else { throw WAVError.unsupported }
        var offset = 12, rate = 0, format = (channels: 0, bits: 0, code: 0)
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self), size = u32(offset + 4), body = offset + 8
            guard body + size <= bytes.count || id == "data" else { throw WAVError.unsupported }
            if id == "fmt ", size >= 16 {
                format = (u16(body + 2), u16(body + 14), u16(body)); rate = u32(body + 4)
            } else if id == "data" {
                guard format.code == 1, format.channels == 1, format.bits == 16, rate > 0 else { throw WAVError.unsupported }
                let end = min(bytes.count, body + size)
                var samples: [Float] = []; samples.reserveCapacity((end - body) / 2)
                var i = body
                while i + 1 < end { samples.append(Float(Int16(bitPattern: UInt16(u16(i)))) / 32768); i += 2 }
                return (samples, rate)
            }
            offset = body + size + size % 2
        }
        throw WAVError.unsupported
    }
}

/// Kept recordings for testing: one folder per recording with `recording.wav` and `recording.json`.
/// Saved only while "Keep recordings for testing" is on; deleting the voice deletes the folder.
public struct VoiceRecordingStore: Sendable {
    public static let audioName = "recording.wav"
    public static let sidecarName = "recording.json"
    /// Soniox tokens cached by the Mac replay tool, next to the recording.
    public static let tokensName = "tokens.json"
    public struct Entry: Sendable, Equatable, Identifiable {
        public let folder: URL
        public let sidecar: VoiceRecordingSidecar
        public let seconds: Double
        public var id: String { sidecar.id }
    }
    public let root: URL
    public init(root: URL) { self.root = root }

    @discardableResult
    public func save(samples: [Float], sidecar: VoiceRecordingSidecar) throws -> URL {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let label = [formatter.string(from: sidecar.date), sidecar.situationName, sidecar.route.displayName]
            .joined(separator: " ").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let folder = root.appendingPathComponent(label + " " + sidecar.id.prefix(6), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(VoiceWAV.encode(samples, sampleRate: sidecar.sampleRate), to: folder.appendingPathComponent(sidecar.audioFile))
        try write(VoiceJSON.encoder.encode(sidecar), to: folder.appendingPathComponent(Self.sidecarName))
        return folder
    }

    /// Newest first. Folders without a readable sidecar are skipped.
    public func list() -> [Entry] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.sidecarName)),
                  let sidecar = try? VoiceJSON.decoder.decode(VoiceRecordingSidecar.self, from: data) else { return nil }
            let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(sidecar.audioFile).path)[.size] as? Int) ?? 44
            return Entry(folder: folder, sidecar: sidecar, seconds: Double(max(0, size - 44) / 2) / Double(max(1, sidecar.sampleRate)))
        }.sorted { $0.sidecar.date > $1.sidecar.date }
    }

    public func deleteAll() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    /// A zip of the given recording folders (and `extras`, such as `profiles.json`) in a temporary directory,
    /// for the share sheet. The archive's top folder is `name`.
    public func archive(_ folders: [URL], extras: [URL] = [], name: String) throws -> URL {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("voice-export-" + UUID().uuidString, isDirectory: true)
        let top = staging.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for folder in folders { try FileManager.default.copyItem(at: folder, to: top.appendingPathComponent(folder.lastPathComponent)) }
        for extra in extras where FileManager.default.fileExists(atPath: extra.path) {
            try FileManager.default.copyItem(at: extra, to: top.appendingPathComponent(extra.lastPathComponent))
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".zip")
        try? FileManager.default.removeItem(at: destination)
        var coordination: NSError?, failure: Error?
        // Coordinated reading "for uploading" zips a directory: the one archiver available on iOS and macOS alike.
        NSFileCoordinator().coordinate(readingItemAt: top, options: .forUploading, error: &coordination) { zipped in
            do { try FileManager.default.copyItem(at: zipped, to: destination) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
        return destination
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
