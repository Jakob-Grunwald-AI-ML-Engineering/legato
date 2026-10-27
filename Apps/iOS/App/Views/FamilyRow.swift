import LegatoModels
import SwiftUI

/// One speech model family in a picker list: name, languages, licence and per-tier size, a latency picker,
/// the install state of the chosen tier, what is on disk, and delete per tier. Tapping the header makes the
/// family live at its chosen tier (load on pick: only that tier downloads). Changing the tier of the live
/// family picks the new tier; changing it on another family only remembers it.
struct FamilyRow: View {
    let family: ModelFamily
    let manager: ModelManager
    let isActive: Bool
    /// The tier shown: the live one for the live family, else the remembered or default tier.
    let tierMs: Int?
    /// This family's pick is waiting for its install.
    let isPending: Bool
    let failure: String?
    let onPick: () -> Void
    let onTier: (Int) -> Void
    /// Deletes one installed tier, or every tier when `nil`.
    let onDelete: (InstalledTier?) -> Void
    /// Stops the download of the given tier (its model id).
    let onCancel: (String) -> Void

    @State private var states: [String: ModelState] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onPick) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(family.name).foregroundStyle(.primary)
                        if let role = family.roleLine { Text(role).font(.caption).foregroundStyle(.tint) }
                        Text(family.detailsLine).font(.caption).foregroundStyle(.secondary)
                        if let chosen { stateLine(chosen).font(.caption) }
                        if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                    }
                    Spacer()
                    if isActive {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    } else if isPending {
                        ProgressView()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("family.\(family.id)")

            if case .downloading? = chosen, let id = family.descriptor(tierMs: tierMs)?.id {
                Button("Cancel download", role: .cancel) { onCancel(id) }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("family.\(family.id).cancel")
            }

            if family.isTiered, let tierMs {
                Picker("Latency", selection: Binding(get: { tierMs }, set: { onTier($0) })) {
                    ForEach(family.tiers, id: \.self) { Text(family.tierLabel($0)).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("family.\(family.id).tier")
            }

            if let note = footprint.note {
                HStack {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach(footprint.installed, id: \.id) { tier in
                            Button("Delete \(tier.tierMs.map { "\($0) ms" } ?? "model")", role: .destructive) { onDelete(tier) }
                        }
                        if footprint.installed.count > 1 {
                            Button("Delete all tiers", role: .destructive) { onDelete(nil) }
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityIdentifier("family.\(family.id).delete")
                }
            }
        }
        .task(id: family.id) {
            for await update in await manager.events(of: family) { states[update.id] = update.state }
        }
    }

    private var chosen: ModelState? {
        family.descriptor(tierMs: tierMs).map { states[$0.id] ?? .notInstalled }
    }

    private var footprint: FamilyFootprint {
        FamilyFootprint(installed: family.members.compactMap { member in
            if case .installed(let bytes) = states[member.id] {
                return InstalledTier(id: member.id, tierMs: member.tierMs, bytes: bytes)
            }
            return nil
        })
    }

    @ViewBuilder private func stateLine(_ state: ModelState) -> some View {
        switch state {
        case .notInstalled:
            Text("Not installed").foregroundStyle(.secondary)
        case .downloading(let fraction):
            HStack {
                Text("Downloading \(Int((fraction * 100).rounded())) %")
                ProgressView(value: fraction).frame(maxWidth: 120)
            }
            .foregroundStyle(.blue)
        case .warming:
            Text("Warming up (first compile)…").foregroundStyle(.blue)
        case .installed(let bytes):
            Text("Installed · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))").foregroundStyle(.green)
        case .failed(let message):
            Text("Failed: \(message)").foregroundStyle(.red)
        }
    }
}
