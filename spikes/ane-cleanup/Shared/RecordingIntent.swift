import AppIntents

struct SpikeToggleIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle ANE spike dictation"
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    @MainActor func perform() async throws -> some IntentResult {
        #if SPIKE_APP
        let host = SpikeHost.shared
        host.trace("intent.entry", ["trigger": "actionButton"])
        if !host.setupComplete {
            try await continueInForeground(alwaysConfirm: false)
            host.trace("intent.setupForegroundHop")
            return .result()
        }
        // A refused start is recorded as a failure. There is no silent foreground retry.
        await host.toggle(trigger: "actionButton")
        #endif
        return .result()
    }
}

/// Deterministic fixture inference, separate from the genuine microphone recording experiment.
struct SpikeFixtureIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Run ANE spike fixture"
    static var supportedModes: IntentModes { [.background] }
    @MainActor func perform() async throws -> some IntentResult {
        #if SPIKE_APP
        SpikeHost.shared.trace("fixture.intentEntry", ["trigger": "actionButtonFixture"])
        await SpikeHost.shared.runFixture(trigger: "actionButtonFixture")
        #endif
        return .result()
    }
}
