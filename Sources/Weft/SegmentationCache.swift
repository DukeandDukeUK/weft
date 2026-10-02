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
    /// Your topic replies not yet checked for follow-ups (kept so the check
    /// still happens after switching conversations or quitting).
    var followUpQueue: [Int64]? = nil
}

enum SegmentationCache {
    /// Tests point this at a scratch folder so they never touch real data.
    nonisolated(unsafe) static var directoryOverride: URL?

    private static func directory() throws -> URL {
        if let dir = directoryOverride {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appending(path: "Weft", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

    /// Fingerprint of what's saved right now: changes with every save, so a
    /// slow job can tell whether the conversation was edited while it ran.
    static func revision(chatId: Int64) -> Int? {
        guard let url = try? fileURL(chatId: chatId),
              let data = try? Data(contentsOf: url) else { return nil }
        return data.hashValue
    }

    /// Forget a conversation's topics and follow-ups (it was removed).
    static func delete(chatId: Int64) {
        guard let url = try? fileURL(chatId: chatId) else { return }
        try? FileManager.default.removeItem(at: url)
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
