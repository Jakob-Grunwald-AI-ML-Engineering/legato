import SwiftUI
import LegatoComposerUI
import LegatoAgent

struct HomeView: View {
    let controller: AppController
    @State private var copied = false
    @State private var confirmClear = false

    private var hasText: Bool { !controller.composer.renderedText.isEmpty || !controller.composer.tail.isEmpty }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Make room for your thoughts.").font(.title2.bold())
                        Text("Speak naturally. Legato shapes your words as you go.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack {
                        Label(controller.notice, systemImage: controller.isDictating ? "waveform" : "circle.fill")
                            .font(.subheadline).foregroundStyle(controller.composer.error == nil ? Color.secondary : .red)
                            .accessibilityIdentifier("home.status")
                        Spacer()
                        ModeChip(mode: controller.composer.mode.rawValue) { value in
                            Task { if let mode = ComposerMode(rawValue: value) { await controller.composer.setMode(mode) } }
                        }
                    }
                    composer
                        .frame(height: hasText ? max(300, geometry.size.height * 0.48) : 190)
                        .background(.background, in: RoundedRectangle(cornerRadius: 24))
                        .overlay { RoundedRectangle(cornerRadius: 24).stroke(.indigo.opacity(0.12)) }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { recordButton; copyButton; clearButton }
                        VStack(spacing: 12) { recordButton; HStack { copyButton; clearButton } }
                    }
                    Label("Tap a word to correct it. Touch and slide to select a phrase, then speak your change.", systemImage: "hand.tap")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink { KeyboardPracticeView() } label: {
                        Label("Try the Legato keyboard", systemImage: "keyboard")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                }
                .padding(20)
                .padding(.bottom, 85)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .navigationTitle("Legato")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear this composition?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear composition", role: .destructive) { Task { await controller.composer.cancel() } }
        } message: { Text("This removes the current text and ends the session.") }
    }

    private var recordButton: some View {
        Button { Task { _ = await controller.toggle() } } label: {
            Label(controller.isDictating ? "Stop" : "Compose", systemImage: controller.isDictating ? "stop.fill" : "mic.fill")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
        }.buttonStyle(.borderedProminent).controlSize(.large)
            .tint(controller.isDictating ? .red : .indigo)
    }
    private var copyButton: some View {
        Button { controller.copy(controller.composer.renderedText); copied = true } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }.buttonStyle(.bordered).controlSize(.large).disabled(controller.composer.renderedText.isEmpty)
            .onChange(of: controller.composer.renderedText) { _, _ in copied = false }
    }
    private var clearButton: some View {
        Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash").frame(minWidth: 24) }
            .buttonStyle(.bordered).controlSize(.large).disabled(!hasText && !controller.isDictating)
            .accessibilityLabel("Clear composition")
    }
    private var composer: some View {
        ComposerView(snapshot: controller.composer.snapshot, tail: controller.composer.tail, dictationRevision: controller.composer.dictationRevision,
            pendingLineIDs: controller.composer.pendingLineIDs, busy: controller.composer.busy,
            correctionDraft: controller.composer.correctionDraft, correctionSubmitting: controller.composer.correctionSubmitting,
            correctionCountdownStart: controller.composer.correctionCountdownStart, correctionCountdownDeadline: controller.composer.correctionCountdownDeadline,
            onSelect: { selection in Task { await controller.composer.select(lineID: selection.lineID, wordID: selection.wordID, endLineID: selection.endLineID, endWordID: selection.endWordID) } },
            onDeselect: { Task { await controller.composer.clearSelection() } },
            onSendCorrection: { Task { await controller.composer.sendCorrection() } },
            onSendInstruction: { Task { await controller.composer.sendInstruction() } },
            onDiscardInstruction: { Task { await controller.composer.discardInstruction() } },
            onPick: { line, word, text in Task { await controller.composer.pick(lineID: line, wordID: word, text: text) } })
    }
}

private struct KeyboardPracticeView: View {
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        Form {
            Section {
                TextField("Write something here…", text: $text, axis: .vertical)
                    .lineLimit(6...16).focused($focused)
                    .accessibilityIdentifier("home.keyboardPractice")
            } footer: { Text("Touch and hold the globe key and choose Legato. This text stays in this practice screen.") }
        }
        .navigationTitle("Try your keyboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = false } } }
    }
}
