import AppKit
import UserNotifications

// MARK: - Notifier

/// Dock badge + banner notifications for new incoming messages.
///
/// "New" = incoming messages newer than the last time you looked at that
/// conversation in Weft (AppSettings.lastViewed). The Dock badge shows the
/// total across added conversations. Banners (optional, with a sound you
/// pick) fire once per new message batch; clicking one opens that
/// conversation.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Newest message already announced per conversation, so nothing is
    /// announced twice. Seeded at launch so old messages aren't announced.
    private var announcedThrough: [Int64: Int64] = [:]

    /// The Mac's built-in alert sounds (/System/Library/Sounds).
    static let systemSounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                               "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ask macOS for permission to show banners (only once; macOS remembers).
    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Don't announce anything that already existed when Weft started.
    func seed(chat: Int64, through rowID: Int64) {
        if announcedThrough[chat] == nil { announcedThrough[chat] = rowID }
    }

    /// Announce new incoming messages in one conversation (if banners are on).
    func announce(_ messages: [ChatMessage], chat: Int64, conversationName: String, settings: AppSettings) {
        let incoming = messages.filter { !$0.isFromMe && $0.id > (announcedThrough[chat] ?? 0) }
        guard let newest = incoming.last else { return }
        announcedThrough[chat] = max(announcedThrough[chat] ?? 0, incoming.map(\.id).max() ?? 0)
        guard settings.notifyBanners else { return }

        let content = UNMutableNotificationContent()
        let sender = newest.senderName.isEmpty ? conversationName : newest.senderName
        content.title = sender
        if sender != conversationName { content.subtitle = conversationName }
        content.body = incoming.count == 1 ? newest.text : "\(newest.text)\n(+\(incoming.count - 1) more)"
        content.sound = Self.sound(named: settings.notifySound)
        content.threadIdentifier = "chat-\(chat)"
        content.userInfo = ["chat": chat]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "weft-\(chat)-\(newest.id)", content: content, trigger: nil)
        )
    }

    /// Settings → "Send test notification".
    func sendTest(settings: AppSettings) async -> String {
        guard await requestPermission() else {
            return "macOS isn't allowing Weft's notifications. Turn them on in System Settings → Notifications → Weft."
        }
        let content = UNMutableNotificationContent()
        content.title = "Weft"
        content.body = "This is how new messages will look."
        content.sound = Self.sound(named: settings.notifySound)
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "weft-test-\(UUID())", content: content, trigger: nil)
        )
        return "Sent — it should appear in a moment."
    }

    static func sound(named name: String) -> UNNotificationSound? {
        switch name {
        case "none": return nil
        case "default", "": return .default
        default: return UNNotificationSound(named: UNNotificationSoundName("\(name).aiff"))
        }
    }

    /// Settings preview: play the sound now.
    static func preview(_ name: String) {
        switch name {
        case "none": return
        case "default", "": NSSound.beep()
        default: NSSound(named: NSSound.Name(name))?.play()
        }
    }

    /// Red number on Weft's Dock icon (empty = no badge).
    func setBadge(_ count: Int, enabled: Bool) {
        NSApp.dockTile.badgeLabel = (enabled && count > 0) ? String(count) : nil
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show banners even while Weft is in front, unless you're already
    /// looking at that conversation.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let chat = notification.request.content.userInfo["chat"] as? Int64
        let showing = await MainActor.run { () -> Bool in
            NSApp.isActive && chat != nil && AppSettings.shared.selectedChatRowID == chat
        }
        return showing ? [] : [.banner, .sound, .list]
    }

    /// Clicking a banner opens Weft on that conversation.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let chat = response.notification.request.content.userInfo["chat"] as? Int64 else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .weftOpenConversation, object: nil, userInfo: ["chat": chat])
        }
    }
}

extension Notification.Name {
    /// A notification banner was clicked: open this conversation.
    static let weftOpenConversation = Notification.Name("weftOpenConversation")
}
