import Foundation

// MARK: - SegmentationCache

/// Persists topic/loop analysis in Application Support so it isn't re-run
/// needlessly. Keyed by (chatId, messageCount, newestRowId): any change to
/// the underlying conversation invalidates the cache.
struct CachedAnalysis: Codable {
    var messageCount: Int
    var newestRowId: Int64
    var generatedAt: Date
    var topics: [Topic]
    var loops: [OpenLoop]
}

enum SegmentationCache {
    private static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appending(path: "Weft", directoryHint: .isDirectory)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            // Weft started life as "Instinct Threader": bring its saved topics
            // and loops along on first launch (copy, so the old app still works).
            let legacy = base.appending(path: "InstinctThreader", directoryHint: .isDirectory)
            if fm.fileExists(atPath: legacy.path) {
                try? fm.copyItem(at: legacy, to: dir)
            }
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(chatId: Int64) throws -> URL {
        try directory().appending(path: "analysis-\(chatId).json", directoryHint: .notDirectory)
    }

    static func load(chatId: Int64) -> CachedAnalysis? {
        guard let url = try? fileURL(chatId: chatId),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedAnalysis.self, from: data)
    }

    static func save(_ analysis: CachedAnalysis, chatId: Int64) throws {
        let url = try fileURL(chatId: chatId)
        let data = try JSONEncoder().encode(analysis)
        try data.write(to: url, options: .atomic)
    }

    static func isFresh(_ cached: CachedAnalysis, messageCount: Int, newestRowId: Int64) -> Bool {
        cached.messageCount == messageCount && cached.newestRowId == newestRowId
    }
}
