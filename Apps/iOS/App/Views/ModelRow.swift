import LegatoModels
import SwiftUI

/// One catalog model in a picker list: name, languages, size and licence, its live install state, and a
/// checkmark when it is the pick. Tapping picks it (load on pick: installs and warms first).
struct ModelRow: View {
    let descriptor: ModelDescriptor
    let manager: ModelManager
    let isSelected: Bool
    /// This row's pick is waiting for its install.
    let isPending: Bool
    let failure: String?
    let onPick: () -> Void

    @State private var state: ModelState = .notInstalled

    var body: some View {
        Button(action: onPick) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(descriptor.displayName).foregroundStyle(.primary)
                    Text(details).font(.caption).foregroundStyle(.secondary)
                    stateLine.font(.caption)
                    if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                } else if isPending {
                    ProgressView()
                }
            }
        }
        .accessibilityIdentifier("model.\(descriptor.id)")
        .task(id: descriptor.id) {
            for await next in await manager.events(for: descriptor.id) { state = next }
        }
    }

    private var details: String {
        var parts: [String] = []
        if !descriptor.languages.isEmpty {
            let shown = descriptor.languages.prefix(8).joined(separator: ", ")
            parts.append(descriptor.languages.count > 8 ? shown + " +\(descriptor.languages.count - 8)" : shown)
        }
        parts.append(ByteCountFormatter.string(fromByteCount: descriptor.approxBytes, countStyle: .file))
        parts.append(descriptor.licence)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var stateLine: some View {
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
