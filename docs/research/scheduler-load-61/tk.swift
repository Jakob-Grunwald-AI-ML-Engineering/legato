import Foundation
let mode = CommandLine.arguments[1]  // bg-cont (continuation, no escalation) | bg-await (await value)
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tk61-\(getpid())")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
func work(_ i: Int) { let u = dir.appendingPathComponent("f\(i)")
  for k in 0..<100 { try? Data(repeating: UInt8(k), count: 4096).write(to: u, options: .atomic)
    if let h = try? FileHandle(forUpdating: u) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data("x\n".utf8)); try? h.synchronize(); try? h.close() } } }
let t0 = Date()
if mode == "bg-await" {
  let ts = (0..<4).map { i in Task.detached(priority: .background) { work(i) } }
  for t in ts { await t.value }
} else {
  await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
    let left = DispatchSemaphore(value: 0)
    for i in 0..<4 { Task.detached(priority: .background) { work(i); left.signal() } }
    Task.detached(priority: .background) { for _ in 0..<4 { left.wait() }; c.resume() }
  }
}
print("task", mode, String(format: "%.2fs", Date().timeIntervalSince(t0)))
try? FileManager.default.removeItem(at: dir)
