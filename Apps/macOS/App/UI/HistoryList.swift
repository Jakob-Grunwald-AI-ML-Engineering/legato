import LegatoCore
import SwiftUI

/// The newest dictations; click a row to copy it, the trash button deletes it.
struct HistoryList: View {
    let entries: [DictationEntry]
    let onCopy: (DictationEntry) -> Void
    let onDelete: (DictationEntry) -> Void

    var body: some View {
        if entries.isEmpty {
            Text("Nothing dictated yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        HistoryRow(entry: entry, onCopy: onCopy, onDelete: onDelete)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
    }
}

private struct HistoryRow: View {
    let entry: DictationEntry
    let onCopy: (DictationEntry) -> Void
    let onDelete: (DictationEntry) -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                onCopy(entry)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(copied ? "Copied" : entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(copied ? Color.accentColor : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(role: .destructive) {
                onDelete(entry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
            .help("Delete")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }
}
