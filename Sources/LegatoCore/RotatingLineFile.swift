import Foundation

/// An append-only log of lines (a journal) that starts over past `rotateBytes`, keeping the previous file once. Several
/// writers may share it: two keyboard controllers in one extension, or two processes. Each append is one line written
/// whole at the file's current end under a lock (`<fileName>.lock` beside it), so lines never interleave or overwrite
/// each other, and a writer whose file another one rotated away writes to the new file, never into the previous one.
///
/// Device run 4 (#299): every keyboard controller held its own handle at its own offset, so an old controller's late
/// lines overwrote the new one's, and after a rotation they went into the previous file at the old offset.
public final class RotatingLineFile {
    public let url: URL
    public let previousURL: URL
    public let rotateBytes: Int
    private let lockURL: URL
    private var fd: Int32 = -1
    private var lockFD: Int32 = -1
    private var failed = false

    public init(directory: URL, fileName: String, previousFileName: String, rotateBytes: Int) {
        url = directory.appendingPathComponent(fileName)
        previousURL = directory.appendingPathComponent(previousFileName)
        lockURL = directory.appendingPathComponent(fileName + ".lock")
        self.rotateBytes = rotateBytes
    }

    deinit {
        if fd >= 0 { close(fd) }
        if lockFD >= 0 { close(lockFD) }
    }

    /// Appends `data` (whole lines, each ending in a line break) in one piece. False once the file cannot be written: later
    /// appends write nothing.
    @discardableResult
    public func append(_ data: Data) -> Bool {
        guard !failed else { return false }
        guard !data.isEmpty else { return true }
        guard openLock() else { failed = true; return false }
        flock(lockFD, LOCK_EX)
        defer { flock(lockFD, LOCK_UN) }
        guard openCurrent() else { failed = true; return false }
        let written = data.withUnsafeBytes { buffer -> Bool in
            guard var base = buffer.baseAddress else { return true }
            var left = buffer.count
            while left > 0 {
                let n = write(fd, base, left)
                if n < 0 { if errno == EINTR { continue }; return false }
                left -= n; base += n
            }
            return true
        }
        guard written else { failed = true; return false }
        var info = stat()
        if fstat(fd, &info) == 0, Int(info.st_size) > rotateBytes {
            // The current file becomes the previous one (replacing it); the next append starts a new one.
            rename(url.path, previousURL.path)
            close(fd); fd = -1
        }
        return true
    }

    private func openLock() -> Bool {
        if lockFD >= 0 { return true }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        lockFD = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        return lockFD >= 0
    }

    /// The handle on the file now at `url` (under the lock): reopened when another writer rotated it away.
    private func openCurrent() -> Bool {
        if fd >= 0 {
            var mine = stat(), current = stat()
            if fstat(fd, &mine) == 0, stat(url.path, &current) == 0, mine.st_ino == current.st_ino, mine.st_dev == current.st_dev {
                return true
            }
            close(fd); fd = -1
        }
        fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        // A file left large by an earlier run starts over before it grows further.
        var info = stat()
        if fstat(fd, &info) == 0, Int(info.st_size) > rotateBytes {
            rename(url.path, previousURL.path)
            close(fd)
            fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        }
        return fd >= 0
    }
}
