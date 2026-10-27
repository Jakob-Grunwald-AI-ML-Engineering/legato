import Foundation

/// One model as the user thinks of it: a name, its languages and licence, and (for speech models) a set of
/// latency tiers that differ only in the audio chunk they work on.
///
/// A family is a view over catalog descriptors; it adds no ids. Each tier stays its own descriptor (and its
/// own download), so persisted picks keep working, and only the tier the user picks is installed.
/// Descriptors with a ``ModelDescriptor/tierMs`` and the same ``ModelDescriptor/family`` form one family;
/// any other descriptor is a family of its own, keyed by its id.
public struct ModelFamily: Sendable, Hashable, Identifiable {
    /// The shared ``ModelDescriptor/family`` of a tiered family, or the id of a lone model.
    public let id: String
    public let name: String
    public let kind: ModelKind
    public let languages: [String]
    public let licence: String
    /// The family's descriptors, ascending by tier (a lone model is one entry).
    public let members: [ModelDescriptor]

    /// Groups `catalog`'s models of `kind` into families, in the order each first appears.
    public static func groups(of catalog: [ModelDescriptor], kind: ModelKind) -> [ModelFamily] {
        var order: [String] = []
        var buckets: [String: [ModelDescriptor]] = [:]
        for descriptor in catalog where descriptor.kind == kind {
            let key = descriptor.tierMs == nil ? descriptor.id : descriptor.family
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(descriptor)
        }
        return order.map { key in
            let members = buckets[key]!.sorted { ($0.tierMs ?? 0) < ($1.tierMs ?? 0) }
            let first = members[0]
            return ModelFamily(
                id: key, name: first.familyName ?? first.displayName, kind: kind, languages: first.languages,
                licence: first.licence, members: members)
        }
    }

    /// Whether the family offers latency tiers (as opposed to being one model).
    public var isTiered: Bool { members.first?.tierMs != nil }

    /// The tiers' chunk sizes in milliseconds, ascending; empty for a lone model.
    public var tiers: [Int] { members.compactMap(\.tierMs) }

    /// The tier used until the user picks one: the middle of three, the larger of two. `nil` for a lone model.
    public var defaultTierMs: Int? {
        let all = tiers
        return all.isEmpty ? nil : all[all.count / 2]
    }

    /// What one tier downloads, approximately: the largest member.
    public var approxTierBytes: Int64 { members.map(\.approxBytes).max() ?? 0 }

    /// The member for `tierMs`; for a lone model, `nil` selects its only member.
    public func descriptor(tierMs: Int?) -> ModelDescriptor? {
        if let tierMs { return members.first { $0.tierMs == tierMs } }
        return isTiered ? nil : members.first
    }

    public func contains(_ modelID: String) -> Bool { members.contains { $0.id == modelID } }

    /// The tier of member `modelID`, or `nil` when it is not a tiered member of this family.
    public func tierMs(ofModel modelID: String) -> Int? {
        members.first { $0.id == modelID }?.tierMs
    }

    /// "de, en · 665 MB per tier · OpenMDW-1.1": what a row shows under the family name.
    public var detailsLine: String {
        var parts: [String] = []
        if !languages.isEmpty {
            let shown = languages.prefix(8).joined(separator: ", ")
            parts.append(languages.count > 8 ? shown + " +\(languages.count - 8)" : shown)
        }
        let size = ByteCountFormatter.string(fromByteCount: approxTierBytes, countStyle: .file)
        parts.append(isTiered ? "\(size) per tier" : size)
        parts.append(licence)
        return parts.joined(separator: " · ")
    }

    /// "Fast · 560 ms": smaller chunks put the first word on screen sooner and are less accurate.
    public func tierLabel(_ ms: Int) -> String {
        let all = tiers
        guard let index = all.firstIndex(of: ms), all.count > 1 else { return "\(ms) ms" }
        let word = index == 0 ? "Fast" : index == all.count - 1 ? "Accurate" : "Balanced"
        return "\(word) · \(ms) ms"
    }
}

/// Persists the latency tier the user wants per family, keyed by ``ModelFamily/id``. Remembering a tier
/// downloads nothing; the pick does.
public struct FamilyTierStore: Sendable {
    // UserDefaults is documented thread-safe but not annotated Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "legato.model.tier.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func tier(for familyID: String) -> Int? {
        defaults.object(forKey: prefix + familyID) as? Int
    }

    /// Persists `ms` for the family; `nil` forgets it (the family default applies).
    public func set(_ ms: Int?, for familyID: String) {
        if let ms {
            defaults.set(ms, forKey: prefix + familyID)
        } else {
            defaults.removeObject(forKey: prefix + familyID)
        }
    }
}

/// Maps a family and a tier to the catalog id the existing pick (``ModelManager/select(_:role:)``) takes.
///
/// The persisted pick stays a plain catalog id, so a selection written before families existed is still
/// valid and reads as "this family at that tier". The tier store only remembers the preference of a family
/// that is not the active one.
public struct FamilySelection: Sendable {
    private let selection: SelectionStore
    private let tiers: FamilyTierStore

    public init(selection: SelectionStore, tiers: FamilyTierStore) {
        self.selection = selection
        self.tiers = tiers
    }

    /// Whether the pick for `role` is one of the family's models.
    public func isActive(_ family: ModelFamily, role: ModelRole) -> Bool {
        selection.selected(for: role).map(family.contains) ?? false
    }

    /// The family the pick for `role` belongs to, if any.
    public func activeFamily(in families: [ModelFamily], role: ModelRole) -> ModelFamily? {
        guard let id = selection.selected(for: role) else { return nil }
        return families.first { $0.contains(id) }
    }

    /// The tier shown for `family`: the picked tier when the family is active, else the remembered tier if
    /// the family has it, else the family default. `nil` for a lone model.
    public func chosenTier(of family: ModelFamily, role: ModelRole) -> Int? {
        if let id = selection.selected(for: role), let active = family.tierMs(ofModel: id) { return active }
        if let stored = tiers.tier(for: family.id), family.tiers.contains(stored) { return stored }
        return family.defaultTierMs
    }

    /// Remembers `tierMs` for the family and returns the catalog id to pick now: the tier's id when the
    /// family is active or `activate` is set, else `nil` (a preference only). `nil` as well, with nothing
    /// remembered, when the family has no such tier. Never changes the pick itself: the manager does that
    /// once the tier is installed.
    @discardableResult
    public func choose(_ family: ModelFamily, tierMs: Int, role: ModelRole, activate: Bool) -> String? {
        guard let descriptor = family.descriptor(tierMs: tierMs) else { return nil }
        tiers.set(tierMs, for: family.id)
        return activate || isActive(family, role: role) ? descriptor.id : nil
    }

    /// The catalog id that makes `family` the live one: its chosen tier (a lone model: itself).
    public func activate(_ family: ModelFamily, role: ModelRole) -> String? {
        family.descriptor(tierMs: chosenTier(of: family, role: role))?.id
    }
}

/// One installed tier of a family and what it takes on disk.
public struct InstalledTier: Sendable, Hashable {
    public let id: String
    public let tierMs: Int?
    public let bytes: Int64

    public init(id: String, tierMs: Int?, bytes: Int64) {
        self.id = id
        self.tierMs = tierMs
        self.bytes = bytes
    }
}

/// What a family occupies on disk.
public struct FamilyFootprint: Sendable, Hashable {
    /// The installed members, ascending by tier.
    public let installed: [InstalledTier]

    public init(installed: [InstalledTier]) { self.installed = installed }

    public var totalBytes: Int64 { installed.reduce(0) { $0 + $1.bytes } }

    /// "On disk: 1120, 2240 ms · 1.2 GB"; `nil` when nothing is installed.
    public var note: String? {
        guard !installed.isEmpty else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let tiers = installed.compactMap(\.tierMs)
        guard !tiers.isEmpty else { return "On disk: \(size)" }
        return "On disk: \(tiers.map(String.init).joined(separator: ", ")) ms · \(size)"
    }
}

extension ModelManager {
    /// The family's installed tiers and their sizes. Never starts an install.
    public func footprint(of family: ModelFamily) async -> FamilyFootprint {
        var installed: [InstalledTier] = []
        for member in family.members {
            if case .installed(let bytes) = await state(of: member.id) {
                installed.append(InstalledTier(id: member.id, tierMs: member.tierMs, bytes: bytes))
            }
        }
        return FamilyFootprint(installed: installed)
    }

    /// Every tier's state now, then every change, until the stream is dropped. One stream for a whole
    /// family row; each update names the model it is about.
    public func events(of family: ModelFamily) async -> AsyncStream<(id: String, state: ModelState)> {
        let (merged, continuation) = AsyncStream<(id: String, state: ModelState)>.makeStream()
        var watchers: [Task<Void, Never>] = []
        for member in family.members {
            let id = member.id
            let stream = await events(for: id)
            watchers.append(Task {
                for await state in stream { continuation.yield((id, state)) }
            })
        }
        continuation.onTermination = { [watchers] _ in watchers.forEach { $0.cancel() } }
        return merged
    }

    /// Deletes every tier of the family (see ``delete(_:)``), which also clears a pick inside it.
    public func delete(family: ModelFamily) async {
        for member in family.members { await delete(member.id) }
    }
}
