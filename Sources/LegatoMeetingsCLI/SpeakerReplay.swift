import Foundation
import LegatoCore
import LegatoMeetingSpeakers
import LegatoMeetings
import LegatoVoiceIdentity

/// `legato meetings speakers --replay`: the after-meeting speaker check on a saved meeting, computed and reported but
/// never saved. Prints counts and names only, never transcript text. Embeddings stay in this process's memory.
enum SpeakerReplay {
    static func run(target: String, threshold: Float?, voiceRoot: String?, usesProfile: Bool, root: String?, console: Console) async throws {
        let detail = try await load(target, root: root)
        var segments = detail.segments
        guard !segments.isEmpty else { throw CommandFailure("the meeting has no transcript to check") }

        // Word times: the segments' own, else the meeting's log for meetings saved before they were kept.
        let timed = segments.filter { $0.words != nil }.count
        let fromLog = RoomLogWords.fill(&segments, folder: detail.folder)

        let voiceFolder = voiceRoot.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
            ?? defaultVoiceRoot()
        let cleanup = MeetingSpeakerCleanup(
            voice: VoiceIdentityService(root: voiceFolder), threshold: threshold ?? SpeakerClustering.defaultThreshold, usesProfile: usesProfile)
        let analysis = try await cleanup.analyze(meeting: detail.meeting, segments: segments, folder: detail.folder)
        let before = SpeakerDirectory(meeting: detail.meeting)
        let result = analysis.apply(to: segments, directory: before)
        console.out(report(detail: detail, segments: segments, timed: timed, fromLog: fromLog, voiceFolder: voiceFolder, usesProfile: usesProfile,
                           threshold: threshold ?? SpeakerClustering.defaultThreshold, analysis: analysis, before: before, result: result))
    }

    // MARK: Loading

    private static func load(_ target: String, root: String?) async throws -> MeetingDetail {
        let path = NSString(string: target).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            let folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("meeting.json").path) else {
                throw CommandFailure("\(folder.path) holds no meeting.json")
            }
            return try await MeetingReader(root: folder.deletingLastPathComponent()).detail(id: folder.lastPathComponent)
        }
        let reader = root.map { MeetingReader(root: URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true)) }
            ?? MeetingReader(root: LegatoCLI.defaultRoot())
        return try await reader.detail(id: target)
    }

    /// The Mac app's voice folder; else the first one that holds a profile, else one that holds the models; else the
    /// folder this process would use.
    private static func defaultVoiceRoot() -> URL {
        let base = VoiceIdentityService.defaultRoot.deletingLastPathComponent()
        let fm = FileManager.default
        let app = base.appendingPathComponent("de.gruenwald.legato.mac", isDirectory: true)
        let folders = ((try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let holds: (URL, String) -> Bool = { fm.fileExists(atPath: $0.appendingPathComponent($1).path) }
        if holds(app, "profile.json") { return app }
        return folders.first { holds($0, "profile.json") } ?? folders.first { holds($0, "CamPlusPlus_v2.mlmodelc") }
            ?? VoiceIdentityService.defaultRoot
    }

    // MARK: Report

    private static func report(
        detail: MeetingDetail, segments: [MeetingSegment], timed: Int, fromLog: Int, voiceFolder: URL, usesProfile: Bool, threshold: Float,
        analysis: SpeakerAnalysis, before: SpeakerDirectory, result: SpeakerReassignment.Result
    ) -> String {
        var lines: [String] = []
        let audio = analysis.audioSeconds
        lines.append("Meeting \(detail.meeting.id.uuidString)")
        lines.append(String(format: "Audio %.0f s (%.1f min); speaker check %.1f s = %.1f s per audio hour (%.0f× real time)",
                            audio, audio / 60, analysis.runSeconds, audio > 0 ? analysis.runSeconds / audio * 3600 : 0,
                            analysis.runSeconds > 0 ? audio / analysis.runSeconds : 0))
        lines.append(String(format: "  of which segmentation %.1f s, voice embeddings %.1f s", analysis.segmentationSeconds, analysis.embeddingSeconds))
        lines.append("Word times: \(timed) of \(segments.count) segments saved with them, \(fromLog) from the log, "
                     + "\(segments.count - timed - fromLog) without (reassigned whole)")
        let e = analysis.embedded
        lines.append("Windows \(analysis.windows); local speakers: \(e.reliable) embedded, \(e.weak) from little speech, "
                     + "\(e.guessed) placed by context, \(e.unplaced) left out; clustering threshold \(threshold)")
        let speech = analysis.timeline.speechSeconds.enumerated().map { String(format: "v%d %.0f s", $0.offset, $0.element) }
        lines.append("Voices: \(analysis.timeline.clusterCount) (\(speech.joined(separator: ", ")))")

        let wordsBefore = wordCounts(segments)
        let wordsAfter = wordCounts(result.segments)
        lines.append("People before: " + people(before, wordsBefore))
        lines.append("People after:  " + people(result.directory, wordsAfter))
        lines.append("Merges: " + (result.merges.isEmpty ? "none" : result.merges.map { "\($0.from) → \($0.into)" }.joined(separator: ", ")))
        lines.append("New people: " + (result.newPeople.isEmpty ? "none" : result.newPeople.joined(separator: ", ")))
        lines.append("Voices → people: " + result.voicePeople.sorted { $0.key < $1.key }.map { "v\($0.key) → \($0.value)" }.joined(separator: ", "))
        lines.append("Splits: \(result.splitSegments) segments split into \(result.splitSegments + result.addedSegments) parts; "
                     + "\(result.movedWords) words moved to another person (merges aside)")
        let changes = changesInside(segments, result.segments, analysis)
        lines.append("Quality (self-labelled from the live segments and the tracks):")
        lines.append("  People: \(wordsBefore.count) before, \(wordsAfter.count) after")
        lines.append("  Changes of person inside a live segment: \(changes.flips), of them \(changes.confirmed) where the louder track switches; "
                     + "short parts (under \(Int(SpeakerReassignment.minimumRunSeconds)) s or \(SpeakerReassignment.minimumRunWords) words): \(changes.short)")

        var user = "Me: " + (result.user.map { "\($0) (\(result.directory.displayName(of: $0) ?? "?"))" } ?? "not found")
        if let voice = analysis.user { user += ", voice v\(voice)" }
        if let mic = analysis.micDominant {
            user += "; microphone voices: " + (mic.filter(\.value).keys.sorted().map { "v\($0)" }.joined(separator: ", ").nonEmpty ?? "none")
        }
        if let similarity = analysis.similarity {
            user += "; profile: " + (similarity.sorted { $0.key < $1.key }.map { String(format: "v%d %.2f", $0.key, $0.value) }
                .joined(separator: ", ").nonEmpty ?? "no voice checked")
        } else {
            user += usesProfile ? "; no usable voice profile in \(voiceFolder.path)" : "; voice profile ignored"
        }
        lines.append(user)

        if analysis.micEnergy != nil {
            let truthBefore = agreement(segments, analysis)
            let truthAfter = agreement(result.segments, analysis)
            lines.append("Track truth: \(truthBefore.decided) words loud on one track (\(truthBefore.mic) microphone, "
                         + "\(truthBefore.decided - truthBefore.mic) system audio)")
            lines.append(String(format: "  Me/Them disagreement (words whose track differs from their person's majority): before %.1f%%, after %.1f%%",
                                truthBefore.disagreement * 100, truthAfter.disagreement * 100))
            let moved = movesAgainstTruth(before: segments, after: result.segments, analysis)
            lines.append("  Moved words loud on one track: \(moved.toward) now with a person mostly on that track (were not), "
                         + "\(moved.away) the other way round, \(moved.neutral) unchanged in that respect")
            if let me = result.user {
                let (precision, recall) = userTruth(result.segments, me, analysis)
                lines.append(String(format: "  Me recall (microphone words given to Me) %.1f%%, Me precision (Me's words loud on the microphone) %.1f%%",
                                    recall * 100, precision * 100))
            }
        } else {
            lines.append("Track truth: one track only (no system audio), nothing to compare")
        }
        lines.append("Nothing was saved.")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Over the live segments that were split: the changes of person inside them, how many of those the louder track
    /// switches at (both parts loud on one track, different ones), and the parts shorter than the cleanup's minimum.
    private static func changesInside(
        _ original: [MeetingSegment], _ result: [MeetingSegment], _ analysis: SpeakerAnalysis
    ) -> (flips: Int, confirmed: Int, short: Int) {
        let originalIDs = Set(original.map(\.id))
        func side(_ part: MeetingSegment) -> MeetingSelf.Side? {
            let sides = (part.words ?? []).compactMap { analysis.side(from: $0.start, to: $0.end) }
            let mic = sides.filter { $0 == .mic }.count, system = sides.count - mic
            return mic > system ? .mic : system > mic ? .system : nil
        }
        var flips = 0, confirmed = 0, short = 0
        var r = 0
        while r < result.count {
            var parts = [result[r]]
            r += 1
            while r < result.count, !originalIDs.contains(result[r].id) {
                parts.append(result[r])
                r += 1
            }
            guard parts.count > 1 else { continue }
            flips += parts.count - 1
            for (a, b) in zip(parts, parts.dropFirst()) {
                if let sa = side(a), let sb = side(b), sa != sb { confirmed += 1 }
            }
            short += parts.filter { part in
                let words = part.words?.count ?? 0
                let seconds = (part.words?.last?.end ?? part.end) - (part.words?.first?.start ?? part.start)
                return words < SpeakerReassignment.minimumRunWords || seconds < SpeakerReassignment.minimumRunSeconds
            }.count
        }
        return (flips, confirmed, short)
    }

    private static func wordCounts(_ segments: [MeetingSegment]) -> [PersonID: Int] {
        var counts: [PersonID: Int] = [:]
        for segment in segments {
            guard let speaker = segment.speaker else { continue }
            counts[speaker, default: 0] += segment.words?.count ?? segment.text.split(whereSeparator: \.isWhitespace).count
        }
        return counts
    }

    private static func people(_ directory: SpeakerDirectory, _ words: [PersonID: Int]) -> String {
        let ids = Set(directory.speakers.keys).union(words.keys).sorted { (Int($0.dropFirst()) ?? 0, $0) < (Int($1.dropFirst()) ?? 0, $1) }
        return ids.map { "\($0) \"\(directory.displayName(of: $0) ?? "?")\" \(words[$0] ?? 0)w" }.joined(separator: ", ")
    }

    /// Words loud on one track, and how many of them differ from the side most of their person's words are on.
    private static func agreement(_ segments: [MeetingSegment], _ analysis: SpeakerAnalysis) -> (decided: Int, mic: Int, disagreement: Double) {
        var sides: [PersonID: (mic: Int, system: Int)] = [:]
        var decided = 0, mic = 0
        for unit in MeetingSpeakerCleanup.units(of: segments) {
            guard let side = analysis.side(from: unit.start, to: unit.end) else { continue }
            let person = segments[unit.segment].speaker ?? "?"
            decided += 1
            if side == .mic {
                mic += 1
                sides[person, default: (0, 0)].mic += 1
            } else {
                sides[person, default: (0, 0)].system += 1
            }
        }
        let minority = sides.values.reduce(0) { $0 + min($1.mic, $1.system) }
        return (decided, mic, decided > 0 ? Double(minority) / Double(decided) : 0)
    }

    /// Words whose person changed and that are loud on one track: how many now sit with a person whose words are mostly
    /// on that track while they did not before (toward), the reverse (away), or neither changed.
    private static func movesAgainstTruth(
        before: [MeetingSegment], after: [MeetingSegment], _ analysis: SpeakerAnalysis
    ) -> (toward: Int, away: Int, neutral: Int) {
        func sides(_ segments: [MeetingSegment]) -> (word: [String: (PersonID?, MeetingSelf.Side?)], major: [PersonID: MeetingSelf.Side]) {
            var word: [String: (PersonID?, MeetingSelf.Side?)] = [:]
            var counts: [PersonID: (mic: Int, system: Int)] = [:]
            for unit in MeetingSpeakerCleanup.units(of: segments) {
                let side = analysis.side(from: unit.start, to: unit.end)
                let person = segments[unit.segment].speaker
                word["\(unit.start)|\(unit.end)"] = (person, side)
                guard let person, let side else { continue }
                if side == .mic { counts[person, default: (0, 0)].mic += 1 } else { counts[person, default: (0, 0)].system += 1 }
            }
            return (word, counts.mapValues { $0.mic >= $0.system ? .mic : .system })
        }
        let old = sides(before), new = sides(after)
        var toward = 0, away = 0, neutral = 0
        for (key, (newPerson, side)) in new.word {
            guard let side, let (oldPerson, _) = old.word[key], oldPerson != newPerson else { continue }
            let was = oldPerson.flatMap { old.major[$0] } == side, now = newPerson.flatMap { new.major[$0] } == side
            if now && !was { toward += 1 } else if was && !now { away += 1 } else { neutral += 1 }
        }
        return (toward, away, neutral)
    }

    /// Of the words given to the user and loud on one track, the share on the microphone; of all microphone words, the
    /// share given to the user.
    private static func userTruth(_ segments: [MeetingSegment], _ user: PersonID, _ analysis: SpeakerAnalysis) -> (Double, Double) {
        var userDecided = 0, userMic = 0, mic = 0
        for unit in MeetingSpeakerCleanup.units(of: segments) {
            guard let side = analysis.side(from: unit.start, to: unit.end) else { continue }
            let isUser = segments[unit.segment].speaker == user
            if isUser { userDecided += 1 }
            if side == .mic {
                mic += 1
                if isUser { userMic += 1 }
            }
        }
        return (userDecided > 0 ? Double(userMic) / Double(userDecided) : 0, mic > 0 ? Double(userMic) / Double(mic) : 0)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
