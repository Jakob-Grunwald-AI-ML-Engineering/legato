import Foundation
// Usage: io <priority> <tasks> <writesPerTask>
let args = CommandLine.arguments
let prio: TaskPriority = ["bg": .background, "util": .utility, "ui": .userInitiated][args[1]]!
let n = Int(args[2])!, w = Int(args[3])!
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("io61-\(getpid())")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let t0 = Date()
await withTaskGroup(of: Void.self) { g in
  for i in 0..<n { g.addTask(priority: prio) {
    let u = dir.appendingPathComponent("f\(i)")
    for k in 0..<w {
      try? Data(repeating: UInt8(k & 255), count: 4096).write(to: u, options: .atomic)
      if let h = try? FileHandle(forUpdating: u) { try? h.seekToEnd(); try? h.write(contentsOf: Data("x\n".utf8)); try? h.synchronize(); try? h.close() }
    }
  } }
}
print(args[1], "tasks", n, "writes", w, String(format: "%.2fs", Date().timeIntervalSince(t0)))
try? FileManager.default.removeItem(at: dir)
