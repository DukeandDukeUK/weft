import Foundation
import AppKit

// MARK: - AppSettings

/// @MainActor-observable app settings, persisted in UserDefaults.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    /// Which AI sorts the conversation. Nil until chosen (or auto-picked).
    var provider: Provider? {
        didSet { defaults.set(provider?.rawValue, forKey: Keys.provider) }
    }
    /// Model per provider; empty = that provider's default.
    private(set) var models: [String: String]
    /// The chosen conversation (chat.ROWID). Nil until picked.
    var selectedChatRowID: Int64? {
        didSet {
            if let selectedChatRowID {
                defaults.set(String(selectedChatRowID), forKey: Keys.chatRowID)
            } else {
                defaults.removeObject(forKey: Keys.chatRowID)
            }
        }
    }
    /// Start replies sent from inside a thread with "Re: <thread title> — "
    /// so the other side knows which subject you mean.
    var prefixThreadReplies: Bool { didSet { defaults.set(prefixThreadReplies, forKey: Keys.prefix) } }
    /// "system" (follow macOS), "light" or "dark".
    var appearance: String {
        didSet {
            defaults.set(appearance, forKey: Keys.appearance)
            Self.apply(appearance: appearance)
        }
    }
    /// The other participant's handle id (phone/email) — used for sending.
    var selectedHandleId: String { didSet { defaults.set(selectedHandleId, forKey: Keys.handleId) } }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let provider = "weft.provider"
        static let models = "weft.models"
        static let chatRowID = "weft.chatRowID"
        static let handleId = "weft.handleId"
        static let prefix = "weft.prefixThreadReplies"
        static let appearance = "weft.appearance"
    }

    private init() {
        let d = UserDefaults.standard
        self.provider = d.string(forKey: Keys.provider).flatMap(Provider.init(rawValue:))
        self.models = d.dictionary(forKey: Keys.models) as? [String: String] ?? [:]
        if let raw = d.string(forKey: Keys.chatRowID) {
            self.selectedChatRowID = Int64(raw)
        } else {
            self.selectedChatRowID = nil
        }
        self.selectedHandleId = d.string(forKey: Keys.handleId) ?? ""
        self.prefixThreadReplies = d.object(forKey: Keys.prefix) as? Bool ?? true
        self.appearance = d.string(forKey: Keys.appearance) ?? "system"
        Self.apply(appearance: appearance)
    }

    /// Nil appearance = follow macOS (including its automatic day/night switch).
    static func apply(appearance: String) {
        let value: NSAppearance? = switch appearance {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
        DispatchQueue.main.async { NSApplication.shared.appearance = value }
    }

    func model(for provider: Provider) -> String {
        models[provider.rawValue] ?? ""
    }

    func setModel(_ model: String, for provider: Provider) {
        models[provider.rawValue] = model.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(models, forKey: Keys.models)
    }

    /// First run: use the first option that's actually on this Mac, in the
    /// order listed (subscriptions first, then local servers).
    func autoPickProviderIfNeeded() async {
        guard provider == nil else { return }
        let found = await ProviderDetector.detectAll()
        guard let first = Provider.allCases.first(where: { found[$0]?.found == true }) else { return }
        if first.isLocal, model(for: first).isEmpty, let m = found[first]?.localModels.first {
            setModel(m, for: first)
        }
        provider = first
    }

    /// The model actually used: your choice, or the recommended one.
    func effectiveModel(for provider: Provider) -> String {
        let chosen = model(for: provider)
        return chosen.isEmpty ? RecommendationStore.shared.recommendedModel(for: provider) : chosen
    }

    /// Nil when no provider is set up yet.
    func makeClient() -> LLMClient? {
        guard let provider else { return nil }
        return LLMClient(provider: provider, model: effectiveModel(for: provider))
    }
}
