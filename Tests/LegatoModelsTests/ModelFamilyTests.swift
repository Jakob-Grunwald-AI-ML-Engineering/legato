import Foundation
import Testing
@testable import LegatoModels

private func tiered(
    _ family: String, name: String, _ tiers: [Int], bytes: Int64 = 1_000, languages: [String] = ["en"],
    licence: String = "MIT", kind: ModelKind = .speechStreaming
) -> [ModelDescriptor] {
    tiers.map { ms in
        ModelDescriptor(
            id: "\(family)-\(ms)", kind: kind, displayName: "\(name) · \(ms) ms", approxBytes: bytes,
            languages: languages, licence: licence, family: family, familyName: name, tierMs: ms)
    }
}

private let batchA = ModelDescriptor(
    id: "batch-a", kind: .speechBatch, displayName: "Batch A", approxBytes: 2_000, licence: "MIT", family: "batch")
private let batchB = ModelDescriptor(
    id: "batch-b", kind: .speechBatch, displayName: "Batch B", approxBytes: 2_000, licence: "MIT", family: "batch")

@Suite struct ModelFamilyGroupingTests {
    @Test func tierDescriptorsOfOneFamilyCollapseIntoOneFamilyOrderedByTier() {
        // Catalog order is scrambled on purpose: tiers sort by chunk size, families by first appearance.
        let catalog = [
            ModelDescriptor(
                id: "nemo-2240", kind: .speechStreaming, displayName: "Nemo · 2240 ms", approxBytes: 1,
                licence: "MIT", family: "nemo", familyName: "Nemo", tierMs: 2240),
        ] + tiered("eou", name: "EOU", [160, 320]) + tiered("nemo", name: "Nemo", [560, 1120])

        let families = ModelFamily.groups(of: catalog, kind: .speechStreaming)

        #expect(families.map(\.id) == ["nemo", "eou"])
        #expect(families[0].tiers == [560, 1120, 2240])
        #expect(families[0].members.map(\.id) == ["nemo-560", "nemo-1120", "nemo-2240"])
        #expect(families[1].tiers == [160, 320])
    }

    @Test func familyTakesNameLanguagesAndLicenceFromItsMembers() {
        let catalog = tiered("nemo", name: "Nemotron multilingual", [560, 1120], languages: ["de", "en"], licence: "OpenMDW-1.1")
        let family = ModelFamily.groups(of: catalog, kind: .speechStreaming)[0]
        #expect(family.name == "Nemotron multilingual")
        #expect(family.languages == ["de", "en"])
        #expect(family.licence == "OpenMDW-1.1")
        #expect(family.kind == .speechStreaming)
    }

    @Test func modelsWithoutATierStayOwnFamiliesEvenWhenTheyShareAFamilyString() {
        let families = ModelFamily.groups(of: [batchA, batchB], kind: .speechBatch)
        #expect(families.map(\.id) == ["batch-a", "batch-b"])
        #expect(families.allSatisfy { !$0.isTiered })
        #expect(families[0].name == "Batch A")
        #expect(families[0].tiers.isEmpty)
        #expect(families[0].descriptor(tierMs: nil) == batchA)
    }

    @Test func groupingKeepsOnlyTheRequestedKind() {
        let catalog = tiered("nemo", name: "Nemo", [560]) + [batchA]
        #expect(ModelFamily.groups(of: catalog, kind: .speechStreaming).map(\.id) == ["nemo"])
        #expect(ModelFamily.groups(of: catalog, kind: .speechBatch).map(\.id) == ["batch-a"])
    }

    @Test func tierLookupMapsBothWays() {
        let family = ModelFamily.groups(of: tiered("nemo", name: "Nemo", [560, 1120, 2240]), kind: .speechStreaming)[0]
        #expect(family.descriptor(tierMs: 1120)?.id == "nemo-1120")
        #expect(family.descriptor(tierMs: 999) == nil)
        #expect(family.tierMs(ofModel: "nemo-2240") == 2240)
        #expect(family.tierMs(ofModel: "other") == nil)
        #expect(family.contains("nemo-560"))
        #expect(!family.contains("other"))
    }

    @Test func approxBytesIsOneTiersDownload() {
        let family = ModelFamily.groups(of: tiered("nemo", name: "Nemo", [560, 1120], bytes: 665), kind: .speechStreaming)[0]
        #expect(family.approxTierBytes == 665)
    }

    @Test func defaultTierIsTheMiddleOfThreeAndTheLargerOfTwo() {
        func tier(_ tiers: [Int]) -> Int? {
            ModelFamily.groups(of: tiered("f", name: "F", tiers), kind: .speechStreaming)[0].defaultTierMs
        }
        #expect(tier([560, 1120, 2240]) == 1120)
        #expect(tier([160, 320]) == 320)
        #expect(tier([1000]) == 1000)
        #expect(ModelFamily.groups(of: [batchA], kind: .speechBatch)[0].defaultTierMs == nil)
    }

    @Test func tierLabelsNameTheLatencyTrade() {
        let three = ModelFamily.groups(of: tiered("n", name: "N", [560, 1120, 2240]), kind: .speechStreaming)[0]
        #expect(three.tierLabel(560) == "Fast · 560 ms")
        #expect(three.tierLabel(1120) == "Balanced · 1120 ms")
        #expect(three.tierLabel(2240) == "Accurate · 2240 ms")
        let two = ModelFamily.groups(of: tiered("e", name: "E", [160, 320]), kind: .speechStreaming)[0]
        #expect(two.tierLabel(160) == "Fast · 160 ms")
        #expect(two.tierLabel(320) == "Accurate · 320 ms")
        let one = ModelFamily.groups(of: tiered("o", name: "O", [800]), kind: .speechStreaming)[0]
        #expect(one.tierLabel(800) == "800 ms")
    }
}

@Suite struct ModelFamilyTextTests {
    private func family(_ tiers: [Int], languages: [String] = ["de", "en"]) -> ModelFamily {
        ModelFamily.groups(
            of: tiered("n", name: "N", tiers, bytes: 665_000_000, languages: languages, licence: "OpenMDW-1.1"),
            kind: .speechStreaming)[0]
    }

    @Test func detailsLineNamesLanguagesPerTierSizeAndLicence() {
        let line = family([560, 1120]).detailsLine
        let size = ByteCountFormatter.string(fromByteCount: 665_000_000, countStyle: .file)
        #expect(line == "de, en · \(size) per tier · OpenMDW-1.1")
    }

    @Test func detailsLineAbbreviatesLongLanguageLists() {
        let many = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]
        #expect(family([560, 1120], languages: many).detailsLine.hasPrefix("a, b, c, d, e, f, g, h +2 · "))
    }

    @Test func roleLineSaysWhatEachKindIsFor() {
        #expect(family([560, 1120]).roleLine == "Live dictation")
        #expect(family([160, 320], languages: ["en"]).roleLine == "English only · live dictation")
        #expect(ModelFamily.groups(of: [batchA], kind: .speechBatch)[0].roleLine == "After meetings · not live")
        #expect(batchA.roleLine == "After meetings · not live")
        let llm = ModelDescriptor(id: "l", kind: .llm, displayName: "L", approxBytes: 1, licence: "MIT", family: "l")
        #expect(llm.roleLine == nil)
    }

    @Test func roleLinesOfTheMeetingModelsAreTheAgreedWords() {
        func row(_ kind: ModelKind) -> ModelDescriptor {
            ModelDescriptor(id: "m-\(kind)", kind: kind, displayName: "M", approxBytes: 1, licence: "MIT", family: "m")
        }
        #expect(row(.speakersLive).roleLine == "Speakers · live")
        #expect(row(.speakersBatch).roleLine == "Speakers · after meetings")
        #expect(row(.echoNoise).roleLine == "Echo & noise cancellation · live")
        #expect(ModelFamily.groups(of: [row(.speakersLive)], kind: .speakersLive)[0].roleLine == "Speakers · live")
    }

    @Test func aLoneModelsSizeIsNotPerTier() {
        let lone = ModelFamily.groups(of: [batchA], kind: .speechBatch)[0]
        let size = ByteCountFormatter.string(fromByteCount: 2_000, countStyle: .file)
        #expect(lone.detailsLine == "\(size) · MIT")
    }

    @Test func onDiskNoteListsTheInstalledTiersAndTheirTotal() {
        let footprint = FamilyFootprint(installed: [
            InstalledTier(id: "n-1120", tierMs: 1120, bytes: 600_000_000),
            InstalledTier(id: "n-2240", tierMs: 2240, bytes: 600_000_000),
        ])
        let total = ByteCountFormatter.string(fromByteCount: 1_200_000_000, countStyle: .file)
        #expect(footprint.note == "On disk: 1120, 2240 ms · \(total)")
    }

    @Test func onDiskNoteIsNilWhenNothingIsInstalled() {
        #expect(FamilyFootprint(installed: []).note == nil)
    }

    @Test func aLoneModelsOnDiskNoteIsJustItsSize() {
        let footprint = FamilyFootprint(installed: [InstalledTier(id: "batch-a", tierMs: nil, bytes: 2_000)])
        #expect(footprint.note == "On disk: \(ByteCountFormatter.string(fromByteCount: 2_000, countStyle: .file))")
    }
}

@Suite struct FamilySelectionTests {
    private let nemo = ModelFamily.groups(of: tiered("nemo", name: "Nemo", [560, 1120, 2240]), kind: .speechStreaming)[0]
    private let eou = ModelFamily.groups(of: tiered("eou", name: "EOU", [160, 320]), kind: .speechStreaming)[0]

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "legato.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func selection(_ defaults: UserDefaults) -> (FamilySelection, SelectionStore, FamilyTierStore) {
        let picks = SelectionStore(defaults: defaults)
        let tiers = FamilyTierStore(defaults: defaults)
        return (FamilySelection(selection: picks, tiers: tiers), picks, tiers)
    }

    @Test func tierStoreRoundTripsAndClears() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let tiers = FamilyTierStore(defaults: defaults)
        #expect(tiers.tier(for: "nemo") == nil)
        tiers.set(2240, for: "nemo")
        #expect(tiers.tier(for: "nemo") == 2240)
        #expect(FamilyTierStore(defaults: defaults).tier(for: "nemo") == 2240, "survives a relaunch")
        #expect(tiers.tier(for: "eou") == nil, "families are independent")
        tiers.set(nil, for: "nemo")
        #expect(tiers.tier(for: "nemo") == nil)
    }

    @Test func aPersistedPickOfOneTierStaysValidAndShowsAsThatFamilysTier() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (choice, picks, tiers) = selection(defaults)
        picks.set("nemo-1120", for: .liveDictation) // written by a build that knew no families
        #expect(tiers.tier(for: "nemo") == nil)
        #expect(choice.isActive(nemo, role: .liveDictation))
        #expect(!choice.isActive(eou, role: .liveDictation))
        #expect(choice.chosenTier(of: nemo, role: .liveDictation) == 1120)
        #expect(choice.activeFamily(in: [eou, nemo], role: .liveDictation)?.id == "nemo")
        #expect(picks.selected(for: .liveDictation) == "nemo-1120", "reading never rewrites the pick")
    }

    @Test func theActivePickWinsOverARememberedTier() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (choice, picks, tiers) = selection(defaults)
        picks.set("nemo-560", for: .liveDictation)
        tiers.set(2240, for: "nemo")
        #expect(choice.chosenTier(of: nemo, role: .liveDictation) == 560)
    }

    @Test func aFamilyThatIsNotActiveUsesItsRememberedTierElseTheDefault() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (choice, picks, tiers) = selection(defaults)
        picks.set("eou-320", for: .liveDictation)
        #expect(choice.chosenTier(of: nemo, role: .liveDictation) == 1120, "default: the middle tier")
        tiers.set(560, for: "nemo")
        #expect(choice.chosenTier(of: nemo, role: .liveDictation) == 560)
        tiers.set(999, for: "nemo")
        #expect(choice.chosenTier(of: nemo, role: .liveDictation) == 1120, "a tier the family lacks is ignored")
    }

    @Test func choosingATierRemembersItAndPicksItWhenTheFamilyIsActive() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (choice, picks, tiers) = selection(defaults)
        picks.set("nemo-1120", for: .liveDictation)

        let toPick = choice.choose(nemo, tierMs: 2240, role: .liveDictation, activate: false)

        #expect(toPick == "nemo-2240")
        #expect(tiers.tier(for: "nemo") == 2240)
        #expect(picks.selected(for: .liveDictation) == "nemo-1120", "choosing alone never switches; the manager does after the install")
    }

    @Test func choosingATierOfAnInactiveFamilyOnlyRemembersIt() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (choice, picks, tiers) = selection(defaults)
        picks.set("eou-160", for: .liveDictation)

        #expect(choice.choose(nemo, tierMs: 560, role: .liveDictation, activate: false) == nil)
        #expect(tiers.tier(for: "nemo") == 560)
        #expect(choice.choose(nemo, tierMs: 560, role: .liveDictation, activate: true) == "nemo-560")
    }

    @Test func choosingATierTheFamilyLacksChangesNothing() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (choice, _, tiers) = selection(defaults)
        #expect(choice.choose(nemo, tierMs: 999, role: .liveDictation, activate: true) == nil)
        #expect(tiers.tier(for: "nemo") == nil)
    }

    @Test func activatingAFamilyPicksItsChosenTier() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (choice, _, tiers) = selection(defaults)
        #expect(choice.activate(eou, role: .liveDictation) == "eou-320", "no tier remembered: the default")
        tiers.set(160, for: "eou")
        #expect(choice.activate(eou, role: .liveDictation) == "eou-160")
    }
}

@Suite struct ModelFamilyManagerTests {
    private func harness() -> (Harness, ModelFamily, [String: FakeInstaller]) {
        let descriptors = tiered("fam", name: "Fam", [560, 1120, 2240])
        let installers = Dictionary(uniqueKeysWithValues: descriptors.map {
            ($0.id, FakeInstaller(folderName: $0.id, weightsBytes: 1_000))
        })
        let h = Harness(installers: installers, catalog: descriptors)
        return (h, ModelFamily.groups(of: descriptors, kind: .speechStreaming)[0], installers)
    }

    @Test func pickingATierDownloadsOnlyThatTier() async throws {
        let (h, family, installers) = harness()
        defer { h.cleanUp() }
        let choice = FamilySelection(selection: h.store, tiers: FamilyTierStore(defaults: h.defaults))

        let id = try #require(choice.choose(family, tierMs: 1120, role: .liveDictation, activate: true))
        try await h.manager.select(id, role: .liveDictation)

        #expect(h.store.selected(for: .liveDictation) == "fam-1120")
        #expect(installers["fam-1120"]!.installCalls == 1)
        #expect(installers["fam-560"]!.installCalls == 0)
        #expect(installers["fam-2240"]!.installCalls == 0)
        #expect(await h.manager.state(of: "fam-560") == .notInstalled)
    }

    @Test func footprintListsTheInstalledTiersAndTheirTotal() async throws {
        let (h, family, _) = harness()
        defer { h.cleanUp() }
        _ = await collect(await h.manager.install("fam-2240"))
        _ = await collect(await h.manager.install("fam-1120"))

        let footprint = await h.manager.footprint(of: family)

        #expect(footprint.installed.map(\.tierMs) == [1120, 2240], "ascending by tier")
        #expect(footprint.installed.map(\.id) == ["fam-1120", "fam-2240"])
        #expect(footprint.installed.allSatisfy { $0.bytes == 1_000 })
        #expect(footprint.totalBytes == 2_000)
    }

    @Test func footprintOfAFamilyWithNothingInstalledIsEmpty() async {
        let (h, family, _) = harness()
        defer { h.cleanUp() }
        let footprint = await h.manager.footprint(of: family)
        #expect(footprint.installed.isEmpty)
        #expect(footprint.totalBytes == 0)
    }

    @Test func deletingAFamilyRemovesEveryTierAndClearsAPickInsideIt() async throws {
        let (h, family, _) = harness()
        defer { h.cleanUp() }
        try await h.manager.select("fam-1120", role: .liveDictation)
        _ = await collect(await h.manager.install("fam-560"))

        await h.manager.delete(family: family)

        #expect(await h.manager.footprint(of: family).installed.isEmpty)
        #expect(h.store.selected(for: .liveDictation) == nil)
        #expect(!h.folderExists("fam-1120") && !h.folderExists("fam-560"))
    }

    @Test func deletingOneTierKeepsTheOthers() async throws {
        let (h, family, _) = harness()
        defer { h.cleanUp() }
        _ = await collect(await h.manager.install("fam-560"))
        _ = await collect(await h.manager.install("fam-1120"))

        await h.manager.delete("fam-560")

        #expect(await h.manager.footprint(of: family).installed.map(\.tierMs) == [1120])
    }

    @Test func familyEventsStartWithEveryTiersStateThenFollowChanges() async {
        let (h, family, _) = harness()
        defer { h.cleanUp() }
        _ = await collect(await h.manager.install("fam-2240"))

        let stream = await h.manager.events(of: family)
        var latest: [String: ModelState] = [:]
        var seenInstalled = false
        var count = 0
        var installing: Task<Void, Never>?
        for await update in stream {
            latest[update.id] = update.state
            count += 1
            if latest.count == 3, installing == nil {
                // The initial snapshot is complete: one state per tier.
                #expect(latest["fam-560"] == .notInstalled)
                #expect(latest["fam-2240"] == .installed(bytes: 1_000))
                installing = Task { _ = await collect(await h.manager.install("fam-1120")) }
            }
            if update.id == "fam-1120", update.state == .installed(bytes: 1_000) { seenInstalled = true; break }
            if count > 100 { break }
        }
        await installing?.value
        #expect(seenInstalled)
    }
}
