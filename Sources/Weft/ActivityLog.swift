import Foundation

// MARK: - Activity log

/// What Weft's AI work did and how long it took, so a stall can be traced.
/// Never message text: only job types, conversation numbers, timings and
/// error kinds. ~/Library/Logs/Weft/activity.log, kept under about 1 MB.
enum ActivityLog {
    nonisolated(unsafe) static var fileOverride: URL?
    private static let queue = DispatchQueue(label: "weft.activitylog")

    static var file: URL {
        fileOverride ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Weft/activity.log")
    }

    static func write(_ line: String) {
        // Tests write only to their own scratch log, never the real one.
        if fileOverride == nil, NSClassFromString("XCTestCase") != nil { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let url = file
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 1_000_000 {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            let data = Data("\(stamp) \(line)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// The kind of error, without its text (which can quote AI output).
    static func kind(of error: Error) -> String {
        if let e = error as? LLMClient.ClientError {
            switch e {
            case .timedOut: return "timed out"
            default: return String(describing: e).components(separatedBy: "(").first ?? "client error"
            }
        }
        return String(describing: type(of: error))
    }
}

// MARK: - Stopping a process and what it started

enum ProcessTree {
    /// Ends `pid` and every process under it (children first).
    static func terminate(_ pid: Int32) {
        for child in children(of: pid) { terminate(child) }
        kill(pid, SIGTERM)
    }

    static func children(of pid: Int32) -> [Int32] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-P", String(pid)]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
    }
}
