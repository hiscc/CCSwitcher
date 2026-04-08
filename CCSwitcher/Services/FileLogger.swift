import Foundation

/// Drop-in replacement for os.Logger that writes to ~/Library/Logs/CCSwitcher.log.
/// Usage: `let log = FileLog("Category"); log.info("message")`
/// Read logs: `cat ~/Library/Logs/CCSwitcher.log` or `tail -f ~/Library/Logs/CCSwitcher.log`
struct FileLog: Sendable {
    private static let shared = FileLogWriter()
    private let category: String

    init(_ category: String) {
        self.category = category
    }

    func info(_ message: String) { FileLog.shared.write("INFO", category, message) }
    func warning(_ message: String) { FileLog.shared.write("WARN", category, message) }
    func error(_ message: String) { FileLog.shared.write("ERROR", category, message) }
    func debug(_ message: String) { FileLog.shared.write("DEBUG", category, message) }
}

private final class FileLogWriter: @unchecked Sendable {
    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.ccswitcher.filelog")
    private let dateFormatter: ISO8601DateFormatter

    private static let maxLogSize: UInt64 = 2 * 1024 * 1024 // 2 MB

    init() {
        let logsDir = NSHomeDirectory() + "/Library/Logs"
        let path = logsDir + "/CCSwitcher.log"

        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Rotate log if it exceeds max size
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64, size > Self.maxLogSize {
            let oldPath = logsDir + "/CCSwitcher.log.old"
            try? fm.removeItem(atPath: oldPath)
            try? fm.moveItem(atPath: path, toPath: oldPath)
        }

        // Append mode — create file if not exists, then open for appending
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: path)
        fileHandle?.seekToEndOfFile()

        let ts = dateFormatter.string(from: Date())
        let header = "\n====== CCSwitcher launched \(ts) ======\n"
        if let data = header.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    func write(_ level: String, _ category: String, _ message: String) {
        queue.async { [weak self] in
            guard let self, let fh = self.fileHandle else { return }
            let ts = self.dateFormatter.string(from: Date())
            let line = "[\(ts)] [\(level)] [\(category)] \(message)\n"
            if let data = line.data(using: .utf8) {
                fh.write(data)
            }
        }
    }
}
