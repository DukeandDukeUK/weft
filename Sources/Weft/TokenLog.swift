import Foundation

// MARK: - Token usage

/// Tokens one AI call used, as reported by the tool or server. Nil when the
/// provider doesn't report counts (Codex and Grok CLIs).
struct TokenUsage: Sendable, Codable, Hashable {
    /// Fresh input tokens.
    var input: Int
    /// Input served from the provider's cache (read + newly written).
    var cachedInput: Int
    var output: Int

    var total: Int { input + cachedInput + output }

    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, cachedInput: a.cachedInput + b.cachedInput, output: a.output + b.output)
    }

    static let zero = TokenUsage(input: 0, cachedInput: 0, output: 0)
}

/// What a call was for, shown in Settings → Token use.
enum CallPurpose: String, Sendable, Codable {
    case fullSort = "Full sort"
    case filing = "Filing new messages"
    case history = "Sorting older history"
    case openLoops = "Open loops"   // stored name; shown as "Follow-ups"
    case connectionTest = "Connection test"
    case summary = "Topic summary"
    case other = "Other"

    /// On-screen name (the stored names above stay as they are so older
    /// logs still load).
    var label: String { self == .openLoops ? "Follow-ups" : rawValue }
}

struct TokenLogEntry: Identifiable, Sendable, Codable, Hashable {
    var id = UUID()
    var date: Date
    var purpose: CallPurpose
    var provider: String
    var model: String
    /// Nil = the provider didn't report counts.
    var usage: TokenUsage?
}

// MARK: - TokenLog

/// Every AI call Weft makes, with its token counts. Kept in Application
/// Support/Weft/token-log.json and shown in Settings → Token use.
@MainActor @Observable
final class TokenLog {
    static let shared = TokenLog()

    /// Oldest entries are dropped past this many.
    private static let maxEntries = 20_000

    private(set) var entries: [TokenLogEntry]

    private init() {
        entries = Self.load()
    }

    /// Safe to call from any thread.
    nonisolated static func record(purpose: CallPurpose, provider: Provider, model: String, usage: TokenUsage?) {
        let entry = TokenLogEntry(
            date: Date(),
            purpose: purpose,
            provider: provider.rawValue,
            model: model.isEmpty ? provider.defaultModel : model,
            usage: usage
        )
        Task { @MainActor in shared.append(entry) }
    }

    private func append(_ entry: TokenLogEntry) {
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    struct Summary {
        var calls = 0
        /// Calls whose provider didn't report counts.
        var unreported = 0
        var usage = TokenUsage.zero
    }

    /// Totals for calls on or after `since` (nil = all time).
    func summary(since: Date?) -> Summary {
        var s = Summary()
        for entry in entries where since.map({ entry.date >= $0 }) ?? true {
            s.calls += 1
            if let usage = entry.usage { s.usage = s.usage + usage } else { s.unreported += 1 }
        }
        return s
    }

    // MARK: Persistence

    /// Tests point this at a scratch file so they never touch the real log.
    nonisolated(unsafe) static var fileOverride: URL?

    private static func fileURL() throws -> URL {
        if let fileOverride { return fileOverride }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = base.appending(path: "Weft", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "token-log.json", directoryHint: .notDirectory)
    }

    private static func load() -> [TokenLogEntry] {
        guard let url = try? fileURL(), let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TokenLogEntry].self, from: data)) ?? []
    }

    private func save() {
        guard let url = try? Self.fileURL() else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
