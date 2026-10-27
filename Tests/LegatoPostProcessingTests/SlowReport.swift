/// Prints a warning when something a test expects to be quick took longer than `budget`. Never fails the test:
/// a shared CI runner can stall any process for seconds, so wall time is reported, not asserted. What the test
/// proves comes from its own expectations (a value that only an early return produces), not from a stopwatch.
func reportIfSlow(_ elapsed: Duration, over budget: Duration, _ what: String) {
    guard elapsed > budget else { return }
    print("⚠️ slow: \(what) took \(elapsed) (budget \(budget)); not a failure")
}
