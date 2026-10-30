import SwiftUI
import LegatoComposerDoc
struct AlternativesPopover: View {
    var word: Word
    var pick: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(word.text).font(.headline)
            ForEach(word.alternatives ?? [], id: \.self) { text in Button(text) { pick(text) } }
            Text("Say the correction now").font(.caption).foregroundStyle(.secondary)
        }.padding()
    }
}
