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
    /// Conversations added to Weft (chat.ROWIDs), in the order added. All of
    /// them are kept sorted in the background.
    var followedChats: [Int64] {
        didSet { defaults.set(followedChats.map(String.init), forKey: Keys.followed) }
    }
    /// Newest message seen per conversation — drives the "new messages" dot.
    private(set) var lastViewed: [String: Int64]

    func markViewed(chat: Int64, through rowID: Int64) {
        guard rowID > (lastViewed[String(chat)] ?? 0) else { return }
        lastViewed[String(chat)] = rowID
        defaults.set(lastViewed, forKey: Keys.lastViewed)
    }

    func lastViewedRowID(chat: Int64) -> Int64 { lastViewed[String(chat)] ?? 0 }

    /// Banner + sound when a new message arrives.
    var notifyBanners: Bool { didSet { defaults.set(notifyBanners, forKey: Keys.notifyBanners) } }
    /// "default", "none", or a Mac alert sound name (e.g. "Glass").
    var notifySound: String { didSet { defaults.set(notifySound, forKey: Keys.notifySound) } }
    /// After the first sort, keep sorting the older history that didn't fit.
    var sortOlderHistory: Bool { didSet { defaults.set(sortOlderHistory, forKey: Keys.sortOlderHistory) } }
    /// ChatGPT (Codex) Fast mode.
    var codexFast: Bool { didSet { defaults.set(codexFast, forKey: Keys.codexFast) } }
    /// Conversations whose sorting is paused (nothing sent to the AI).
    var pausedChats: Set<Int64> {
        didSet { defaults.set(pausedChats.map(String.init), forKey: Keys.paused) }
    }
    /// Conversations that skip older-history sorting.
    var recentOnlyChats: Set<Int64> {
        didSet { defaults.set(recentOnlyChats.map(String.init), forKey: Keys.recentOnly) }
    }
    /// Conversations you've OK'd sending to the AI (first-sort question).
    /// Kept for older versions; the real check is per destination below.
    var consentedChats: Set<Int64> {
        didSet { defaults.set(consentedChats.map(String.init), forKey: Keys.consented) }
    }
    /// Which destinations you've OK'd for each conversation ("local", or a
    /// cloud provider). OK'ing a local model doesn't cover a cloud AI.
    private(set) var consents: [String: [String]]

    static func destination(_ p: Provider) -> String { p.isLocal ? "local" : p.rawValue }

    func hasConsent(_ chat: Int64, for provider: Provider? = nil) -> Bool {
        guard let p = provider ?? self.provider else { return false }
        return consents[String(chat)]?.contains(Self.destination(p)) ?? false
    }

    func grantConsent(_ chat: Int64, for provider: Provider? = nil) {
        guard let p = provider ?? self.provider else { return }
        var list = consents[String(chat)] ?? []
        if !list.contains(Self.destination(p)) { list.append(Self.destination(p)) }
        consents[String(chat)] = list
        consentedChats.insert(chat)
        defaults.set(consents, forKey: Keys.consents)
    }

    /// Before consent existed, sorted conversations were already being sent
    /// to the AI in use; treat that as OK'd, once.
    func grantLegacyConsentIfNeeded(_ chat: Int64) {
        guard consents[String(chat)] == nil else { return }
        grantConsent(chat)
    }
    /// Notifications say "New message" / "Follow-up reminder" instead of
    /// showing the text (it can appear on the lock screen).
    var notifyHidePreviews: Bool { didSet { defaults.set(notifyHidePreviews, forKey: Keys.hidePreviews) } }
    /// Red count on Weft's Dock icon.
    var dockBadge: Bool { didSet { defaults.set(dockBadge, forKey: Keys.dockBadge) } }
    /// The notifications step of first-time setup has been shown.
    var notificationsOnboarded: Bool { didSet { defaults.set(notificationsOnboarded, forKey: Keys.notifOnboarded) } }

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
        static let followed = "weft.followedChats"
        static let notifyBanners = "weft.notifyBanners"
        static let notifySound = "weft.notifySound"
        static let dockBadge = "weft.dockBadge"
        static let hidePreviews = "weft.notifyHidePreviews"
        static let codexFast = "weft.codexFast"
        static let consented = "weft.consentedChats"
        static let consents = "weft.consents"
        static let paused = "weft.pausedChats"
        static let recentOnly = "weft.recentOnlyChats"
        static let sortOlderHistory = "weft.sortOlderHistory"
        static let notifOnboarded = "weft.notificationsOnboarded"
        static let lastViewed = "weft.lastViewed"
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
        var followed = (d.stringArray(forKey: Keys.followed) ?? []).compactMap(Int64.init)
        // Earlier versions followed exactly one conversation.
        if followed.isEmpty, let only = d.string(forKey: Keys.chatRowID).flatMap(Int64.init) { followed = [only] }
        self.followedChats = followed
        self.lastViewed = (d.dictionary(forKey: Keys.lastViewed) as? [String: Int64]) ?? [:]
        self.notifyBanners = d.object(forKey: Keys.notifyBanners) as? Bool ?? true
        self.notifySound = d.string(forKey: Keys.notifySound) ?? "default"
        self.dockBadge = d.object(forKey: Keys.dockBadge) as? Bool ?? true
        self.notifyHidePreviews = d.bool(forKey: Keys.hidePreviews)
        self.codexFast = d.bool(forKey: Keys.codexFast)
        self.consentedChats = Set((d.stringArray(forKey: Keys.consented) ?? []).compactMap(Int64.init))
        self.consents = (d.dictionary(forKey: Keys.consents) as? [String: [String]]) ?? [:]
        self.pausedChats = Set((d.stringArray(forKey: Keys.paused) ?? []).compactMap(Int64.init))
        self.recentOnlyChats = Set((d.stringArray(forKey: Keys.recentOnly) ?? []).compactMap(Int64.init))
        self.sortOlderHistory = d.object(forKey: Keys.sortOlderHistory) as? Bool ?? true
        self.notificationsOnboarded = d.bool(forKey: Keys.notifOnboarded)
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
        var client = LLMClient(provider: provider, model: effectiveModel(for: provider))
        client.fast = provider == .codex && codexFast
        return client
    }
}
