import LegatoCore
import SwiftUI

/// Local observations for inspection; nothing here changes recognition or writing preferences.
struct CorrectionsView: View {
    let store: CorrectionStore
    @State private var records: [CorrectionRecord] = []
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("Edits are saved locally and deleted separately from dictation history. Personal vocabulary and style learning are not enabled yet.")
                Text("Capture follows readable text in the same field for up to 10 minutes. Leaving the field, switching keyboards or unreadable text can end capture. Host changes may include autocorrect.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            if records.isEmpty {
                Text("No captured edits yet.").foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                DisclosureGroup {
                    detail("Original transcription", record.rawText)
                    detail("Inserted by Legato", record.insertedText)
                    detail("Before edit", record.beforeText)
                    detail("After edit", record.afterText)
                    Text("\(record.platform) · Device locale: \(record.localeIdentifier)").font(.caption).foregroundStyle(.secondary)
                    Text(record.origin == .keyboard ? "Observed after Legato keyboard input — may include autocorrect" : "Observed host change — may include autocorrect")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Delete captured edit", role: .destructive) {
                        Task { await remove(record) }
                    }
                    .accessibilityIdentifier("corrections.delete")
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(record.removed.isEmpty ? "(insertion)" : record.removed) → \(record.replacement.isEmpty ? "(deletion)" : record.replacement)")
                            .lineLimit(3)
                        Text(record.date, format: .dateTime.day().month().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Captured edits")
        .accessibilityIdentifier("corrections.list")
        .toolbar { Button("Refresh") { Task { await reload() } }.accessibilityIdentifier("corrections.refresh") }
        .task {
            while !Task.isCancelled {
                await reload()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "(empty)" : value).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
    }

    @MainActor private func reload() async {
        do { records = try await store.recent(); error = nil }
        catch { self.error = "Could not load captured edits: \(error.localizedDescription)" }
    }

    @MainActor private func remove(_ record: CorrectionRecord) async {
        do { try await store.delete(id: record.id); await reload() }
        catch { self.error = "Could not delete captured edit: \(error.localizedDescription)" }
    }
}
