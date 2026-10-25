import Foundation

/// Shared constants, App Group defaults and the shared log file. Compiled into all three targets.
enum Spike {
    static let groupID = "group.de.gruenwald.legato"

    static var defaults: UserDefaults { UserDefaults(suiteName: groupID) ?? .standard }
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    enum Key {
        static let heartbeat = "hb.time"          // Double, unix seconds
        static let level = "hb.level"             // Float 0...1
        static let pid = "hb.pid"                 // Int
        static let active = "session.active"      // Bool
        static let dictId = "dict.id"             // Double, unix seconds; identifies one dictation
        static let dictTarget = "dict.target"     // "keyboard" | "scratch": where the text goes
        static let text = "dict.text"             // full text of current dictation (finalized + volatile)
        static let textSeq = "dict.textSeq"       // Int, increments on every update
        static let textFinal = "dict.final"       // Bool
        static let dictState = "dict.state"       // idle | listening | finishing | error:<msg>
        static let kbdVisible = "kbd.visible"     // Bool, written by the keyboard
        static let kbdVisibleAt = "kbd.visibleAt" // Double, unix seconds; refreshed every 1 s while visible
    }

    enum Note {
        static let toggle = "de.gruenwald.legato.spike1.toggle"              // keyboard -> app (fallback path)
        static let text = "de.gruenwald.legato.spike1.text"                  // app -> keyboard
    }
}

enum SpikeLog {
    private static let lock = NSLock()

    // Under Library/ so `devicectl device copy from` can read it.
    static var fileURL: URL? { Spike.containerURL?.appendingPathComponent("Library/spike.log") }

    static func write(_ source: String, _ message: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let line = "\(f.string(from: Date())) [\(source) \(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
        lock.lock(); defer { lock.unlock() }
        guard let url = fileURL, let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    static func tail(bytes: Int = 6000) -> String {
        guard let url = fileURL, let h = try? FileHandle(forReadingFrom: url) else { return "(no log)" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let data = (try? h.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? Data().write(to: url)
    }
}
