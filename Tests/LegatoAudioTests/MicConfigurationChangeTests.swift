import AVFAudio
import Synchronization
import Testing
@testable import LegatoAudio

@Suite struct MicConfigurationChangeTests {
    @Test func aForeignEngineDoesNotInvalidateTheMicrophone() {
        let current = AVAudioEngine(), foreign = AVAudioEngine()
        let events = Mutex<[MicSource.ConfigurationChange]>([])
        let observer = MicSource.observeConfigurationChanges(of: current, isCurrent: { true }) { change in
            events.withLock { $0.append(change) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: foreign)
        #expect(events.withLock { $0.count } == 0)
    }

    @Test func aHealthyCurrentEngineDoesNotInvalidateTheMicrophone() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // Native engine state without opening a microphone or the system output device.
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1_024)
        try engine.start()
        defer { engine.stop() }
        try #require(engine.isRunning)
        let events = Mutex<[MicSource.ConfigurationChange]>([])
        let observer = MicSource.observeConfigurationChanges(of: engine, isCurrent: { true }) { change in
            events.withLock { $0.append(change) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        #expect(events.withLock { $0.count } == 0)
        #expect(engine.isRunning)
    }

    @Test func aStoppedCurrentEngineInvalidatesItsMicrophone() throws {
        let engine = AVAudioEngine()
        let events = Mutex<[MicSource.ConfigurationChange]>([])
        let observer = MicSource.observeConfigurationChanges(of: engine, isCurrent: { true }) { change in
            events.withLock { $0.append(change) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        let changes = events.withLock { $0 }
        #expect(changes.count == 1)
        #expect(try #require(changes.first).requiresStop)
    }

    @Test func aQueuedChangeCannotInvalidateAReplacementLease() throws {
        let oldEngine = AVAudioEngine()
        let current = Mutex(true)
        let events = Mutex<[MicSource.ConfigurationChange]>([])
        let observer = MicSource.observeConfigurationChanges(of: oldEngine, isCurrent: { current.withLock { $0 } }) { change in
            events.withLock { $0.append(change) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: oldEngine)
        let queued = try #require(events.withLock { $0.first })
        #expect(queued.requiresStop)
        current.withLock { $0 = false } // stop/start superseded the engine before the app handles its event
        #expect(!queued.requiresStop)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: oldEngine)
        #expect(events.withLock { $0.count } == 1)
    }
}
