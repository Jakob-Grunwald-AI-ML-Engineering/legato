import LegatoCore
import SwiftUI

/// The local correction archive and its review decisions, shared by the Mac and iPhone apps.
public struct CorrectionsView: View {
    let store: CorrectionStore
    @State private var records: [CorrectionRecord] = []
    @State private var review: CorrectionReviewSnapshot?
    @State private var error: String?
    @State private var updating = false
    @State private var editing: CorrectionCandidate?
    @State private var spelling = ""
    @State private var revision: String?

    public init(store: CorrectionStore) {
        self.store = store
    }

    public var body: some View {
        List {
            if let review {
                Section {
                    Toggle("Use personal vocabulary and preferences", isOn: Binding(
                        get: { review.enabled },
                        set: { enabled in
                            update { try await store.setPersonalizationEnabled(enabled) }
                        }
                    ))
                    .disabled(updating)
                    .accessibilityIdentifier("corrections.enabled")
                    Text("Your keyboard uses words you type and choose. Recurring spellings can go to your speech provider. Cleanup uses matching vocabulary and approved examples.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if review.candidates.isEmpty {
                        Text("Your vocabulary appears here as you type, choose suggestions and correct dictations.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Personalization")
                }

                candidateSection("Automatic vocabulary", candidates: review.candidates.filter(\.isAutomatic))
                candidateSection("Keyboard vocabulary", candidates: review.candidates.filter(\.isKeyboardOnly))
                candidateSection("Suggested preferences", candidates: review.candidates.filter { $0.state == .pending && !$0.isAutomatic && !$0.isKeyboardOnly })
                candidateSection("Approved preferences", candidates: review.candidates.filter { $0.state == .approved })
                let dismissed = review.candidates.filter { $0.state == .dismissed }
                if !dismissed.isEmpty {
                    Section {
                        DisclosureGroup("Dismissed (\(dismissed.count))") {
                            ForEach(dismissed, id: \.id) { candidateRow($0) }
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            Section {
                if records.isEmpty {
                    Text("No captured edits yet.").foregroundStyle(.secondary)
                }
                ForEach(records) { recordRow($0) }
            } header: {
                Text("Captured edits")
            } footer: {
                Text("Captured edits are stored on this device and deleted separately from dictation history. Capture follows readable text in the same field for up to 10 minutes. Host changes can include autocorrect.")
            }
        }
        .navigationTitle("Captured edits")
        .accessibilityIdentifier("corrections.list")
        .toolbar {
            Button("Refresh") { Task { await reload(force: true) } }
                .accessibilityIdentifier("corrections.refresh")
        }
        .sheet(item: $editing) { candidate in
            VStack(alignment: .leading) {
                TextField("Preferred spelling", text: $spelling)
                    .onSubmit { saveSpelling(candidate) }
                HStack {
                    Button("Cancel") { editing = nil }
                    Button("Save") { saveSpelling(candidate) }
                        .disabled(spelling.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
        }
        .task {
            while !Task.isCancelled {
                await reload()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    @ViewBuilder private func candidateSection(_ title: String, candidates: [CorrectionCandidate]) -> some View {
        if !candidates.isEmpty {
            Section {
                ForEach(candidates, id: \.id) { candidateRow($0) }
            } header: {
                Text(title)
            }
        }
    }

    private func candidateRow(_ candidate: CorrectionCandidate) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading) {
                if !candidate.records.isEmpty {
                    Text(basisDescription(candidate.basis))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                HStack {
                    if candidate.kind == .vocabulary && candidate.state != .dismissed {
                        Button("Edit spelling") { spelling = candidate.after; editing = candidate }
                    }
                    switch candidate.state {
                    case .pending:
                        if !candidate.isAutomatic {
                            Button(candidate.isKeyboardOnly ? "Use in dictation" : "Approve") { decide(.approved, candidate) }
                        }
                        Button("Dismiss") { decide(.dismissed, candidate) }
                    case .approved:
                        Button("Remove preference", role: .destructive) { decide(.dismissed, candidate) }
                    case .dismissed:
                        Button("Review again") { decide(.pending, candidate) }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(updating)
                ForEach(candidate.records) { recordRow($0) }
                ForEach(candidate.keyboardEvidence) { event in
                    VStack(alignment: .leading) {
                        Text(event.term)
                        Text(eventLabel(event)).font(.caption).foregroundStyle(.secondary)
                        Text(event.date, format: .dateTime.day().month().year().hour().minute()).font(.caption)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading) {
                if candidate.kind == .vocabulary {
                    Text(candidate.after)
                } else {
                    replacement(candidate.before, candidate.after)
                }
                let kind = candidate.kind == .vocabulary ? "Vocabulary" : "Style"
                let count = candidate.supportCount
                Text("\(kind) · \(count) \(count == 1 ? "observation" : "observations")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func eventLabel(_ event: TermEvidence) -> String {
        switch event.origin {
        case .selection: "Selected on the keyboard"
        case .typed: "Typed on the keyboard"
        case .recognition: "Heard in dictation"
        }
    }

    private func saveSpelling(_ candidate: CorrectionCandidate) {
        let text = spelling
        editing = nil
        update { try await store.editSpelling(text, for: candidate) }
    }

    private func basisDescription(_ basis: CorrectionBasis) -> String {
        switch basis {
        case .recognition: "Likely a recognition correction. The original transcript contains the wording you changed."
        case .cleanup: "Likely a cleanup correction. Compare the original transcript with the inserted text."
        case .uncertain: "The edit could reflect a wording choice, a correction or host autocorrect. Check the examples before approving."
        }
    }

    private func recordRow(_ record: CorrectionRecord) -> some View {
        DisclosureGroup {
            detail("Original transcription", record.rawText)
            detail("Inserted by Legato", record.insertedText)
            detail("Before edit", record.beforeText)
            detail("After edit", record.afterText)
            Text("\(record.platform) · Device locale: \(record.localeIdentifier)").font(.caption).foregroundStyle(.secondary)
            Text(record.origin == .keyboard ? "Observed after Legato keyboard input · may include autocorrect" : "Observed host change · may include autocorrect")
                .font(.caption).foregroundStyle(.secondary)
            Button("Delete captured edit", role: .destructive) {
                update { try await store.delete(id: record.id) }
            }
            .buttonStyle(.bordered)
            .disabled(updating)
            .accessibilityIdentifier("corrections.delete")
        } label: {
            VStack(alignment: .leading) {
                replacement(record.removed, record.replacement)
                Text(record.date, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func replacement(_ before: String, _ after: String) -> some View {
        Text("\(before.isEmpty ? "(insertion)" : before) → \(after.isEmpty ? "(deletion)" : after)")
            .lineLimit(3)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "(empty)" : value).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func decide(_ state: CorrectionReviewState, _ candidate: CorrectionCandidate) {
        update { try await store.setReview(state, for: candidate) }
    }

    private func update(_ action: @escaping @MainActor () async throws -> Void) {
        guard !updating else { return }
        updating = true
        Task {
            defer { updating = false }
            do {
                try await action()
                await reload(force: true)
            } catch { self.error = "Could not save the change: \(error.localizedDescription)" }
        }
    }

    private func reload(force: Bool = false) async {
        do {
            let token = try await store.revisionToken()
            if force || token != revision {
                let latest = try await store.recent()
                review = try await store.reviewSnapshot()
                records = latest
                revision = token
                error = nil
            }
        } catch { self.error = "Could not load captured edits: \(error.localizedDescription)" }
    }
}
