import AVFAudio
import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoAppleSpeech

@Suite("Locale resolution")
struct LocaleResolverTests {
    @Test func requestedLocaleWinsOverCurrent() async throws {
        let got = try await LocaleResolver.resolve(
            requested: Locale(identifier: "en_US"), current: Locale(identifier: "de_DE")
        ) { $0 }
        #expect(got.identifier == "en_US")
    }

    @Test func nilFallsBackToCurrent() async throws {
        let got = try await LocaleResolver.resolve(requested: nil, current: Locale(identifier: "de_DE")) { $0 }
        #expect(got.identifier == "de_DE")
    }

    @Test func usesTheSupportedEquivalent() async throws {
        let got = try await LocaleResolver.resolve(requested: Locale(identifier: "en_DE"), current: .current) { _ in
            Locale(identifier: "en_US")
        }
        #expect(got.identifier == "en_US")
    }

    @Test func unsupportedThrowsTypedError() async {
        await #expect(throws: AppleSpeechError.unsupportedLocale("tlh")) {
            _ = try await LocaleResolver.resolve(requested: Locale(identifier: "tlh"), current: .current) { _ in nil }
        }
    }
}

@Suite("Phrase spacing")
struct PhraseSpacerTests {
    @Test func firstFinalHasNoLeadingSpace() {
        var s = PhraseSpacer()
        #expect(s.apply("Hello world.", isFinal: true) == "Hello world.")
    }

    @Test func laterFinalsAreSeparatedByOneSpace() {
        var s = PhraseSpacer()
        _ = s.apply("Hello world.", isFinal: true)
        #expect(s.apply("Second phrase.", isFinal: true) == " Second phrase.")
    }

    @Test func noDoubleSpaceWhenAlreadySeparated() {
        var s = PhraseSpacer()
        _ = s.apply("Hello ", isFinal: true)
        #expect(s.apply("there", isFinal: true) == "there")
        var t = PhraseSpacer()
        _ = t.apply("Hello", isFinal: true)
        #expect(t.apply(" there", isFinal: true) == " there")
    }

    @Test func volatileIsSeparatedFromCommittedButDoesNotCommit() {
        var s = PhraseSpacer()
        _ = s.apply("One.", isFinal: true)
        #expect(s.apply("tw", isFinal: false) == " tw")
        #expect(s.apply("two", isFinal: false) == " two")
        #expect(s.apply("Two.", isFinal: true) == " Two.")
    }

    @Test func volatileBeforeAnyFinalHasNoSpace() {
        var s = PhraseSpacer()
        #expect(s.apply("hel", isFinal: false) == "hel")
    }

    @Test func emptyTextStaysEmpty() {
        var s = PhraseSpacer()
        _ = s.apply("One.", isFinal: true)
        #expect(s.apply("", isFinal: true) == "")
        #expect(s.apply("", isFinal: false) == "")
    }
}

@Suite("PCM packing")
struct PCMPackerTests {
    private let spec = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

    @Test func float32TargetCopiesSamples() throws {
        let fmt = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buf = try #require(PCMPacker.buffer(from: AudioChunk(samples: [0, 0.25, -0.5], format: spec), format: fmt))
        #expect(buf.frameLength == 3)
        #expect(buf.floatChannelData?[0][1] == 0.25)
        #expect(buf.floatChannelData?[0][2] == -0.5)
    }

    @Test func int16TargetScalesAndClamps() throws {
        let fmt = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let buf = try #require(PCMPacker.buffer(from: AudioChunk(samples: [0, 0.5, -0.5, 2.0, -2.0], format: spec), format: fmt))
        #expect(buf.frameLength == 5)
        let d = try #require(buf.int16ChannelData?[0])
        #expect(d[0] == 0)
        #expect(abs(Int(d[1]) - 16_384) <= 1)
        #expect(abs(Int(d[2]) + 16_384) <= 1)
        #expect(d[3] == Int16.max)
        #expect(d[4] >= -Int16.max)
    }

    @Test func emptyChunkYieldsNil() throws {
        let fmt = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        #expect(PCMPacker.buffer(from: AudioChunk(samples: [], format: spec), format: fmt) == nil)
    }
}

@Suite("PCM stream packing")
struct PCMStreamPackerTests {
    @Test func resamplingKeepsOneConverterAcrossChunks() throws {
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let spec = AudioFormatSpec(sampleRate: 48_000, channelCount: 1)
        let packer = PCMStreamPacker(format: target)
        let samples = (0..<4800).map { 0.5 * sinf(2 * .pi * 440 * Float($0) / 48_000) }
        var total = 0
        for _ in 0..<10 {
            let buf = try #require(packer.buffer(from: AudioChunk(samples: samples, format: spec)))
            total += Int(buf.frameLength)
        }
        // 10 x 100 ms at 48 kHz is 1 s: 16000 frames at 16 kHz, within 1%.
        #expect(abs(total - 16_000) <= 160, "got \(total) frames")
    }
}

private struct Limit: Error {}
private struct Other: Error, Equatable {}

private func locale(_ id: String) -> Locale { Locale(identifier: id) }

/// Fake asset inventory: records releases; `capacity` models the reservation cap.
private final class FakeInventory: @unchecked Sendable {
    var reservedList: [Locale]
    let capacity: Int
    var released: [String] = []
    var attempts: [String] = []
    var attemptResult: Result<Bool, any Error>?

    init(reserved: [String], capacity: Int) {
        reservedList = reserved.map(locale)
        self.capacity = capacity
    }

    func reserve(_ l: Locale) async throws {
        try await LocaleReservation.reserve(
            l, maximum: capacity,
            reserved: { self.reservedList },
            attempt: { l in
                self.attempts.append(l.identifier)
                if let r = self.attemptResult { return try r.get() }
                if self.reservedList.count >= self.capacity { throw Limit() }
                self.reservedList.append(l)
                return true
            },
            release: { l in
                self.released.append(l.identifier)
                self.reservedList.removeAll { $0.identifier == l.identifier }
                return true
            })
    }
}

@Suite("Locale reservation")
struct LocaleReservationTests {
    @Test func nonLimitErrorEvictsNothingAndPropagates() async {
        let inv = FakeInventory(reserved: ["en_US"], capacity: 2)
        inv.attemptResult = .failure(Other())
        await #expect(throws: Other()) { try await inv.reserve(locale("de_DE")) }
        #expect(inv.released.isEmpty)
        #expect(inv.reservedList.map(\.identifier) == ["en_US"])
    }

    @Test func atTheLimitTheOldestReservationIsEvicted() async throws {
        let inv = FakeInventory(reserved: ["en_US", "fr_FR"], capacity: 2)
        try await inv.reserve(locale("de_DE"))
        #expect(inv.released == ["en_US"])
        #expect(inv.reservedList.map(\.identifier) == ["fr_FR", "de_DE"])
    }

    @Test func belowTheLimitNothingIsEvicted() async throws {
        let inv = FakeInventory(reserved: ["en_US"], capacity: 2)
        try await inv.reserve(locale("de_DE"))
        #expect(inv.released.isEmpty)
    }

    @Test func alreadyReservedAtTheLimitEvictsNothing() async throws {
        let inv = FakeInventory(reserved: ["en_US", "fr_FR"], capacity: 2)
        inv.attemptResult = .success(false) // a held locale is reported as `false`, not as an error
        try await inv.reserve(locale("fr_FR"))
        #expect(inv.released.isEmpty)
    }

    @Test func rejectedReservationThrowsTypedError() async {
        let inv = FakeInventory(reserved: [], capacity: 2)
        inv.attemptResult = .success(false)
        await #expect(throws: AppleSpeechError.reservationFailed("de_DE")) { try await inv.reserve(locale("de_DE")) }
    }
}

@Suite("Asset install progress")
struct AssetInstallProgressTests {
    private func collect(_ stream: AsyncStream<Double>) async -> [Double] {
        var out: [Double] = []
        for await p in stream { out.append(p) }
        return out
    }

    private func install(completed: Int64, run: @escaping @Sendable (Progress) async throws -> Void) -> AssetInstall {
        let progress = Progress(totalUnitCount: 10)
        progress.completedUnitCount = completed
        return AssetInstall(progress: progress, run: { try await run(progress) })
    }

    @Test func failedInstallEndsBelowOne() async {
        let values = await collect(AssetInstallProgress.stream(pollInterval: .milliseconds(5)) {
            self.install(completed: 3) { _ in throw Other() }
        })
        #expect(values.allSatisfy { $0 < 1.0 }, "got \(values)")
    }

    @Test func failedPreparationEndsBelowOne() async {
        let values = await collect(AssetInstallProgress.stream { throw Other() })
        #expect(values.allSatisfy { $0 < 1.0 }, "got \(values)")
    }

    @Test func successfulInstallEndsAtOne() async {
        let values = await collect(AssetInstallProgress.stream(pollInterval: .milliseconds(5)) {
            self.install(completed: 3) { p in
                try await Task.sleep(for: .milliseconds(20))
                p.completedUnitCount = 10
            }
        })
        #expect(values.last == 1.0, "got \(values)")
        #expect(values.dropLast().allSatisfy { $0 < 1.0 })
    }

    @Test func alreadyInstalledYieldsOne() async {
        let values = await collect(AssetInstallProgress.stream { nil })
        #expect(values == [1.0])
    }
}
