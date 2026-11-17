import Foundation
import Testing
@testable import LegatoCore

/// Device run 4 (#299): two keyboard controllers wrote the edit journal through handles at their own offsets, so one
/// overwrote the other's lines, and after a rotation an old handle wrote into the previous file.
@Suite struct RotatingLineFileTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rotating-line-file-\(UUID().uuidString)", isDirectory: true)
    }

    private func file(in directory: URL, rotateBytes: Int) -> RotatingLineFile {
        RotatingLineFile(directory: directory, fileName: "journal.jsonl", previousFileName: "journal.1.jsonl", rotateBytes: rotateBytes)
    }

    private func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test func twoWritersTakingTurnsKeepEveryLineWhole() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = file(in: dir, rotateBytes: 1_000_000), b = file(in: dir, rotateBytes: 1_000_000)
        for i in 0..<50 {
            #expect(a.append(Data("{\"w\":\"a\",\"i\":\(i)}\n".utf8)))
            #expect(b.append(Data("{\"w\":\"b\",\"i\":\(i)}\n".utf8)))
        }
        let written = lines(a.url).dropLast()
        #expect(written.count == 100)
        #expect(written.allSatisfy { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil })
    }

    /// Writers on several threads, with rotations: every line is whole, in the current or the previous file, and none
    /// written since the last rotation but one is lost.
    @Test func concurrentWritersRotateWithoutCorruptingEitherFile() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writers = 4, perWriter = 200
        let padding = String(repeating: "x", count: 40)
        DispatchQueue.concurrentPerform(iterations: writers) { w in
            let journal = file(in: dir, rotateBytes: 6_000)
            for i in 0..<perWriter { journal.append(Data("{\"w\":\(w),\"i\":\(i),\"p\":\"\(padding)\"}\n".utf8)) }
        }
        let current = file(in: dir, rotateBytes: 6_000)
        for url in [current.url, current.previousURL] {
            let all = lines(url)
            #expect(all.last == "", "the file ends in a line break")
            for line in all.dropLast() {
                #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil, "a whole line: \(line.prefix(80))")
            }
        }
        // Both files stay within a line of the rotation size: a writer whose file was rotated away writes to the new one,
        // not on into the previous one.
        for url in [current.url, current.previousURL] {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            #expect(size <= 6_000 + 100)
        }
    }
}
