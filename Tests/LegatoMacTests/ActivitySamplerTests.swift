#if os(macOS)
import Testing
@testable import LegatoMac

@Suite struct ActivitySamplerTests {
    @Test func loadIsBusyTicksOverAllTicksSinceTheLastReading() {
        let before = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let now = CPUTicks(user: 130, system: 60, idle: 850, nice: 60)  // 50 busy of 100
        #expect(now.load(since: before) == 0.5)
        #expect(now.load(since: now) == 0, "no ticks passed")
    }

    @Test func aCounterThatWrappedPastItsThirtyTwoBitsStillGivesTheLoadSinceTheLastReading() {
        // The user counter wrapped: it went from 10 below the top to 30 past zero, i.e. 40 ticks.
        let before = CPUTicks(user: UInt32.max - 9, system: 100, idle: UInt32.max - 59, nice: 0)
        let now = CPUTicks(user: 30, system: 100, idle: 0, nice: 0)  // idle wrapped too: 60 ticks
        #expect(now.load(since: before) == 0.4)
    }
}
#endif
