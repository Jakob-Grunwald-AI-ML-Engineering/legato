import LegatoAppServices
import LegatoMeetings
import SwiftUI

/// A rounded panel of Settings, the look every page shares.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}

/// The Meetings page of Settings: whether the summary writes itself, and the summary sections.
struct SettingsMeetingsPage: View {
    private let settings = MeetingSettings(defaults: .standard)
    @State private var automatic = true
    @State private var sections: [SummarySection] = []
    @State private var ticked: Set<SectionID> = []
    @State private var editing: SectionDraft?

    /// A custom section being written; `id` nil is a new one.
    struct SectionDraft: Identifiable {
        let id = UUID()
        var sectionID: SectionID?
        var heading = ""
        var instruction = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            summaryCard
            sectionsCard
            additionalSections
        }
        .task { reload() }
        .sheet(item: $editing) { draft in
            SectionEditor(draft: draft) { save($0) }
        }
    }

    /// The place for the Meetings sections that come later (call detection, calendar, the command-line tool): each
    /// is one `SettingsCard` placed here, below the summary sections.
    @ViewBuilder private var additionalSections: some View {
        SettingsCallDetectionCard()
        SettingsCalendarCard()
    }

    // MARK: Summary

    private var summaryCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Summary", systemImage: "text.badge.checkmark").font(.headline)
                Toggle("Write the summary when a meeting ends", isOn: $automatic)
                    .onChange(of: automatic) { _, value in settings.summarizeAutomatically = value }
                Text("Claude writes the summary from the transcript with your key. Off leaves it to the Summarize button.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Sections

    private var sectionsCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Summary sections", systemImage: "list.bullet.rectangle").font(.headline)
                Text("Ticked sections are written for every new meeting; a meeting can change its own. The order here is the order in the summary.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        if index > 0 { Divider() }
                        sectionRow(section, index: index)
                    }
                }
                Button("Add Section…") { editing = SectionDraft() }.controlSize(.small)
            }
        }
    }

    private func sectionRow(_ section: SummarySection, index: Int) -> some View {
        HStack(spacing: 10) {
            Toggle(section.heading, isOn: tick(section.id)).toggleStyle(.checkbox)
            if !section.isBuiltIn { Text("Custom").font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            if !section.isBuiltIn {
                Button { edit(section) } label: { Image(systemName: "pencil") }
                    .help("Edit \(section.heading)").accessibilityLabel("Edit \(section.heading)")
                Button { delete(section) } label: { Image(systemName: "trash") }
                    .help("Delete \(section.heading)").accessibilityLabel("Delete \(section.heading)")
            }
            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0).help("Move up").accessibilityLabel("Move \(section.heading) up")
            Button { move(index, by: 2) } label: { Image(systemName: "chevron.down") }
                .disabled(index == sections.count - 1).help("Move down").accessibilityLabel("Move \(section.heading) down")
        }
        .buttonStyle(.borderless).padding(.vertical, 6)
    }

    // MARK: Actions

    private func tick(_ id: SectionID) -> Binding<Bool> {
        Binding(
            get: { ticked.contains(id) },
            set: { on in
                if on { ticked.insert(id) } else { ticked.remove(id) }
                settings.defaultSectionIDs = sections.map(\.id).filter(ticked.contains)
            })
    }

    private func edit(_ section: SummarySection) {
        editing = SectionDraft(sectionID: section.id, heading: section.heading, instruction: section.instruction)
    }

    private func save(_ draft: SectionDraft) {
        if let id = draft.sectionID {
            settings.updateSection(SummarySection(id: id, heading: draft.heading, instruction: draft.instruction))
        } else {
            settings.addSection(heading: draft.heading, instruction: draft.instruction)
        }
        reload()
    }

    private func delete(_ section: SummarySection) {
        settings.deleteSection(id: section.id)
        reload()
    }

    /// `offset` is a list's move destination: -1 puts the row above its neighbour, 2 below the one under it.
    private func move(_ index: Int, by offset: Int) {
        settings.moveSections(fromOffsets: IndexSet(integer: index), toOffset: index + offset)
        reload()
    }

    private func reload() {
        automatic = settings.summarizeAutomatically
        sections = settings.allSections
        ticked = Set(settings.defaultSectionIDs)
    }
}

/// The sheet that writes one custom section: its heading and what Claude writes under it.
private struct SectionEditor: View {
    @State var draft: SettingsMeetingsPage.SectionDraft
    let save: (SettingsMeetingsPage.SectionDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool {
        !draft.heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.sectionID == nil ? "New Section" : "Edit Section").font(.headline)
            TextField("Heading", text: $draft.heading).textFieldStyle(.roundedBorder)
            Text("What should Claude write under this heading?").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $draft.instruction).font(.body).scrollContentBackground(.hidden).padding(4)
                .frame(minHeight: 120).background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityLabel("Section instruction")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(!isValid)
            }
        }
        .padding(20).frame(width: 420)
    }
}
