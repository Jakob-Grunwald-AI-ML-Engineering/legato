import Testing
@testable import LegatoAppServices

@Suite @MainActor struct SerialReloadTests {
    /// Reloads that read a counter and land the read after a pause: asks during a read fold into one more read, and
    /// what lands last is the newest value.
    @Test func asksDuringAReloadFoldIntoOneMoreAndTheNewestReadLandsLast() async {
        let reloads = SerialReload()
        var source = 0
        var shown = -1
        var reads = 0
        func reload() async {
            reads += 1
            let read = source
            try? await Task.sleep(for: .milliseconds(20))
            shown = read
        }
        source = 1
        let first = Task { await reloads.run(reload) }
        while reads == 0 { await Task.yield() }
        source = 2
        let second = Task { await reloads.run(reload) }
        let third = Task { await reloads.run(reload) }
        await first.value
        await second.value
        await third.value
        #expect(shown == 2, "the save made before the second ask is seen")
        #expect(reads == 2, "the two asks during the first read fold into one")
        await reloads.run(reload)
        #expect(reads == 3, "an ask after the reloads ended starts a new one")
    }
}
