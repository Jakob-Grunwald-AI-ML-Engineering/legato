import Testing
@testable import LegatoKeyboardCore

private func final(committed: String, finalText: String?, delivery: HostDelivery?) -> HostState {
    var state = hostState(phase: .idle, committed: committed)
    state.finalText = finalText
    state.delivery = delivery
    return state
}

@Suite struct DictationVersionsLandedTests {
    @Test func aSwappedRunOffersRawAndCleanedWithTheCleanedShown() throws {
        var landed = cursor(committedCount: 15, finalApplied: true)
        landed.finalReplaced = true
        let versions = try #require(DictationVersions.landed(
            state: final(committed: "um hello world ", finalText: "Hello, world.", delivery: .replace), cursor: landed))
        #expect(versions.texts == ["um hello world", "Hello, world."])
        #expect(versions.current == 1)
        #expect(versions.shown == "Hello, world. ")
        #expect(versions.runID == "run-1" && versions.documentID == "doc-A")
    }

    @Test func aClipboardRunShowsTheRawText() throws {
        let versions = try #require(DictationVersions.landed(
            state: final(committed: "um hello world ", finalText: "Hello, world.", delivery: .clipboard),
            cursor: cursor(committedCount: 15, finalApplied: true)))
        #expect(versions.texts == ["um hello world", "Hello, world."])
        #expect(versions.current == 0)
        #expect(versions.shown == "um hello world ")
    }

    @Test func aHeldRunShowsTheInsertedTextWithNothingAfterIt() throws {
        let versions = try #require(DictationVersions.landed(
            state: final(committed: "um hello world ", finalText: "Hello, world.", delivery: .hold),
            cursor: cursor(committedCount: 15, finalApplied: true)))
        #expect(versions.texts == ["um hello world", "Hello, world."])
        #expect(versions.current == 1)
        #expect(versions.shown == "Hello, world.")
    }

    @Test func aRunWithoutCleanupHasOneVersionToRefine() throws {
        let versions = try #require(DictationVersions.landed(
            state: final(committed: "hello world ", finalText: nil, delivery: nil),
            cursor: cursor(committedCount: 12, finalApplied: true)))
        #expect(versions.texts == ["hello world"])
        #expect(versions.current == 0)
        #expect(!versions.hasPrevious && !versions.hasNext)
    }

    @Test func nothingIsOfferedWhenTheTextDidNotLand() {
        var failed = cursor(committedCount: 15, finalApplied: false)
        failed.finalReplaced = false
        #expect(DictationVersions.landed(
            state: final(committed: "um hello world ", finalText: "Hello, world.", delivery: .replace), cursor: failed) == nil)
    }

    @Test func nothingIsOfferedBeforeTheRunEndsOrForAnotherRun() {
        #expect(DictationVersions.landed(
            state: hostState(committed: "hello "), cursor: cursor(committedCount: 6, finalApplied: false)) == nil)
        #expect(DictationVersions.landed(
            state: final(committed: "hello ", finalText: nil, delivery: nil),
            cursor: cursor(runID: "run-0", committedCount: 6, finalApplied: true)) == nil)
        #expect(DictationVersions.landed(state: final(committed: "", finalText: nil, delivery: nil),
                                         cursor: cursor(finalApplied: true)) == nil)
    }
}

@Suite struct DictationVersionsSwapTests {
    private func versions(current: Int = 1) -> DictationVersions {
        DictationVersions(
            runID: "run-1", documentID: "doc-A", texts: ["um hello world", "Hello, world."], current: current,
            trailing: " ")
    }

    @Test func swappingBackReplacesTheShownVersionWithThePreviousOne() throws {
        let ops = try #require(versions().swapOps(to: 0, contextBefore: "Dear Bob, Hello, world. "))
        #expect(ops == [.deleteBackward(14), .insert("um hello world ")])
    }

    @Test func aSharedBeginningStays() throws {
        let v = DictationVersions(
            runID: "run-1", documentID: "doc-A", texts: ["See you Friday.", "See you Thursday."], current: 0, trailing: "")
        #expect(v.swapOps(to: 1, contextBefore: "See you Friday.") == [.deleteBackward(7), .insert("Thursday.")])
    }

    @Test func noSwapWhenTheFieldNoLongerEndsWithTheShownVersion() {
        #expect(versions().swapOps(to: 0, contextBefore: "Hello, world. and then") == nil)
        #expect(versions().swapOps(to: 0, contextBefore: "") == nil)
    }

    @Test func noSwapToAVersionThatDoesNotExistOrIsShown() {
        #expect(versions().swapOps(to: 2, contextBefore: "Hello, world. ") == nil)
        #expect(versions().swapOps(to: 1, contextBefore: "Hello, world. ") == [])
    }

    @Test func showingAVersionMovesTheCurrentOne() {
        var v = versions()
        #expect(v.hasPrevious && !v.hasNext)
        v.show(0)
        #expect(v.current == 0 && v.shown == "um hello world ")
        #expect(!v.hasPrevious && v.hasNext)
    }

    @Test func aRefinementIsAddedOnceAtTheEnd() {
        var v = versions()
        #expect(v.add("Hello world!") == 2)
        #expect(v.texts == ["um hello world", "Hello, world.", "Hello world!"])
        #expect(v.add("Hello, world.") == 1) // already there
        #expect(v.add("  Hello world!\n") == 2) // trimmed
        #expect(v.texts.count == 3)
    }
}
