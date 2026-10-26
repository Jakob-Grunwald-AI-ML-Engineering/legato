import LegatoCore
import SwiftUI

/// Recent dictations, with the raw text under a cleaned one. Tap copies; hold for the raw text; swipe deletes. All access goes through `AppController`.
struct HistoryView: View {
    let controller: AppController
    @State private var entries: [DictationEntry] = []
    @State private var copiedID: UUID?

    var body: some View {
        List {
            ForEach(entries) { entry in
                Button {
                    controller.copy(entry.text)
                    copiedID = entry.id
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text).lineLimit(4).foregroundStyle(.primary)
                        if let raw = entry.rawText {
                            Text("Raw: \(raw)").lineLimit(4).font(.footnote).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(entry.date, format: .dateTime.day().month().hour().minute())
                            if copiedID == entry.id { Text("Copied").foregroundStyle(.green) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button("Copy") { controller.copy(entry.text) }
                    if let raw = entry.rawText {
                        Button("Copy raw text") { controller.copy(raw) }
                    }
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { entries[$0].id }
                entries.remove(atOffsets: offsets)
                Task {
                    for id in ids { await controller.deleteEntry(id: id) }
                }
            }
        }
        .overlay {
            if entries.isEmpty { ContentUnavailableView("No dictations yet", systemImage: "text.bubble") }
        }
        .navigationTitle("History")
        .task { entries = await controller.recentEntries() }
    }
}
