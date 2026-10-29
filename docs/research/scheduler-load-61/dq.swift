import Foundation
let q = DispatchQueue.global(qos: CommandLine.arguments[1] == "bg" ? .background : .userInitiated)
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dq61-\(getpid())")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let g = DispatchGroup(); let t0 = Date()
for i in 0..<4 { q.async(group: g) {
  let u = dir.appendingPathComponent("f\(i)")
  for k in 0..<100 { try? Data(repeating: UInt8(k), count: 4096).write(to: u, options: .atomic)
    if let h = try? FileHandle(forUpdating: u) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data("x\n".utf8)); try? h.synchronize(); try? h.close() } } } }
g.wait(); print("dispatch", CommandLine.arguments[1], String(format: "%.2fs", Date().timeIntervalSince(t0)))
try? FileManager.default.removeItem(at: dir)
