import Foundation

struct HistoryEntry: Sendable {
    let transaction: Transaction
    let touched: Set<String>
    let stamps: [String: Int]
}
