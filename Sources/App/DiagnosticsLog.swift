import Foundation

/// Tiny rolling status log at ~/Library/Logs/Aura/aura.log — handy when something
/// (permissions, audio routing) isn't working and you want to see what Aura sees.
enum DiagnosticsLog {
    private static let queue = DispatchQueue(label: "app.aura.log")
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Aura", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("aura.log")
        try? Data().write(to: file)
        return file
    }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            handle.write(Data(line.utf8))
            // Keep the file small.
            if let size = try? handle.offset(), size > 512_000 { try? Data(line.utf8).write(to: url) }
        }
    }
}
