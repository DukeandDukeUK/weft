import Foundation

// MARK: - Recommendations

/// Which model to suggest for each provider. A copy is built into the app;
/// at launch Weft also fetches `recommendations.json` from the GitHub
/// project, so suggestions can be updated (e.g. a better local model)
/// without shipping a new version. The fetch sends no personal data.
struct Recommendations: Codable, Sendable {
    struct Model: Codable, Sendable, Hashable {
        let id: String
        let label: String
    }
    struct LocalTier: Codable, Sendable {
        let minMemoryGB: Double
        let model: String
        let size: String
    }
    struct ProviderEntry: Codable, Sendable {
        var recommended: String?
        var note: String?
        var models: [Model]?
        var localTiers: [LocalTier]?
    }

    var version: Int
    var providers: [String: ProviderEntry]

    func entry(_ provider: Provider) -> ProviderEntry? { providers[provider.rawValue] }

    /// The local model that suits this Mac's memory best.
    func recommendedLocalModel(memoryGB: Double = Recommendations.memoryGB) -> LocalTier? {
        entry(.ollama)?.localTiers?
            .sorted { $0.minMemoryGB > $1.minMemoryGB }
            .first { memoryGB >= $0.minMemoryGB }
    }

    static var memoryGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }
}

@MainActor @Observable
final class RecommendationStore {
    static let shared = RecommendationStore()

    private(set) var current: Recommendations

    private static let remoteURL = URL(string: "https://raw.githubusercontent.com/DukeandDukeUK/weft/main/recommendations.json")!
    private static let cacheKey = "weft.recommendations"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(Recommendations.self, from: data) {
            current = cached
        } else {
            current = Self.builtIn
        }
    }

    /// Fetch the latest suggestions; keep what we have if offline.
    func refresh() async {
        var request = URLRequest(url: Self.remoteURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let fresh = try? JSONDecoder().decode(Recommendations.self, from: data),
              fresh.version >= 1 else { return }
        current = fresh
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    func recommendedModel(for provider: Provider) -> String {
        if provider == .ollama, let tier = current.recommendedLocalModel() { return tier.model }
        return current.entry(provider)?.recommended ?? provider.defaultModel
    }

    /// Same content as recommendations.json at the time of this build.
    static let builtIn = Recommendations(version: 1, providers: [
        "claude": .init(recommended: "claude-sonnet-5-5", note: "Sorts well and uses little of your plan.", models: [
            .init(id: "claude-sonnet-5-5", label: "Sonnet 5.5"),
            .init(id: "claude-opus-5-5", label: "Opus 5.5"),
            .init(id: "claude-haiku-5-5", label: "Haiku 5.5"),
            .init(id: "claude-haiku-4-5-20251001", label: "Haiku 4.5"),
        ]),
        "codex": .init(recommended: "gpt-6-luna", note: "Light on your ChatGPT plan's usage."),
        "grok": .init(recommended: "grok-4.7", note: "Grok's current default."),
        "gemini": .init(note: "Uses the Gemini CLI's own default model."),
        "ollama": .init(note: "Free and private; sized to this Mac's memory.", localTiers: [
            .init(minMemoryGB: 16, model: "qwen3:8b", size: "5 GB"),
            .init(minMemoryGB: 0, model: "qwen3:4b", size: "2.5 GB"),
        ]),
        "lmstudio": .init(note: "Uses whichever model you have loaded in LM Studio."),
    ])
}

// MARK: - ModelCatalog

/// The models to offer in Settings for each provider — read live from the
/// tool where it publishes a list, otherwise from the recommendations.
enum ModelCatalog {
    struct Option: Hashable, Identifiable, Sendable {
        let id: String
        let label: String
    }

    static func options(for provider: Provider, status: ProviderStatus?, recommendations: Recommendations) async -> [Option] {
        let listed: [Option]
        switch provider {
        case .claude, .gemini:
            listed = (recommendations.entry(provider)?.models ?? []).map { Option(id: $0.id, label: $0.label) }
        case .codex:
            listed = await Task.detached { codexModels() }.value
        case .grok:
            listed = await Task.detached { grokModels() }.value
        case .ollama, .lmstudio:
            listed = (status?.localModels ?? []).map { Option(id: $0, label: $0) }
        }
        // Make sure the recommended model is always offered, even when the
        // live list couldn't be read.
        if let rec = recommendations.entry(provider)?.recommended, !listed.contains(where: { $0.id == rec }) {
            return [Option(id: rec, label: rec)] + listed
        }
        return listed
    }

    /// The Codex CLI caches the models your ChatGPT plan offers.
    private static func codexModels() -> [Option] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/models_cache.json")
        struct Entry: Decodable {
            let slug: String
            let display_name: String?
            let visibility: String?
        }
        struct Cache: Decodable { let models: [Entry] }
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return [] }
        return cache.models
            .filter { $0.visibility == nil || $0.visibility == "list" }
            .map { Option(id: $0.slug, label: $0.display_name ?? $0.slug) }
    }

    /// `grok models` prints e.g. "  * grok-4.7 (default)".
    private static func grokModels() -> [Option] {
        guard let path = CommandLocator.find("grok") else { return [] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["models"]
        var env = ProcessInfo.processInfo.environment
        for key in Provider.grok.keyVariablesToStrip { env.removeValue(forKey: key) }
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let listStart = text.range(of: "Available models:") else { return [] }
        return text[listStart.upperBound...]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { line in
                let name = line.replacingOccurrences(of: "* ", with: "")
                    .components(separatedBy: " (").first ?? ""
                return name.isEmpty ? nil : Option(id: name, label: name)
            }
    }
}
