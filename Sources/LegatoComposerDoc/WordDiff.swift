import Foundation

/// A fresh longest-common-subsequence diff preserves complete surviving word records.
enum WordDiff {
    static func reconcile(old: [Word], proposed: [Word], origin: TransactionOrigin) -> [Word] {
        if origin == .undo || origin == .asr { return proposed }
        let n = old.count, m = proposed.count
        var lengths = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lengths[i][j] = old[i].text == proposed[j].text ? 1 + lengths[i + 1][j + 1] : max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
        }
        var result = proposed.map { Word(text: $0.text, language: $0.language, pinned: origin == .user && $0.pinned) }
        var i = 0, j = 0
        while i < n && j < m {
            if old[i].text == proposed[j].text { result[j] = old[i]; i += 1; j += 1 }
            else if lengths[i + 1][j] >= lengths[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return result
    }
    static func words(_ text: String) -> [Word] { text.split(whereSeparator: \.isWhitespace).map { Word(text: String($0)) } }
}
