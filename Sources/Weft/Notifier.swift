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

    /// macOS notifications only exist for a real app bundle; anywhere else
    /// (tests, command-line tools) calling them crashes, so skip them.
    static let available = Bundle.main.bundleURL.pathExtension == "app"

    /// The notification center, or nil outside the app.
    private var center: UNUserNotificationCenter? { Self.available ? UNUserNotificationCenter.current() : nil }

    override private init() {
        super.init()
        center?.delegate = self
    }

    /// Ask macOS for permission to show banners (only once; macOS remembers).
    func requestPermission() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
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
        center?.add(
            UNNotificationRequest(identifier: "weft-\(chat)-\(newest.id)", content: content, trigger: nil)
        )
    }

    /// Reminders for follow-ups: one per open follow-up with a due date or
    /// snooze in the future. Replaces this conversation's earlier ones.
    func syncReminders(loops: [OpenLoop], chat: Int64, conversationName: String, settings: AppSettings) {
        guard let center else { return }
        let prefix = "weft-loop-\(chat)-"
        center.getPendingNotificationRequests { pending in
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }
        guard settings.notifyBanners else { return }
        let now = Date()
        for loop in loops where loop.status == .open {
            let when = [loop.snoozedUntil, loop.dueDate].compactMap { $0 }.filter { $0 > now }.min()
            guard let when else { continue }
            let content = UNMutableNotificationContent()
            content.title = loop.isOverdue(at: when) || loop.dueDate == when ? "Due: \(loop.title)" : "Reminder: \(loop.title)"
            content.subtitle = conversationName
            content.body = loop.detail
            content.sound = Self.sound(named: settings.notifySound)
            content.userInfo = ["chat": chat, "loop": loop.id.uuidString]
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: when)
            center.add(UNNotificationRequest(
                identifier: prefix + loop.id.uuidString,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            ))
        }
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
        try? await center?.add(
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
        let info = response.notification.request.content.userInfo
        guard let chat = info["chat"] as? Int64 else { return }
        let loop = info["loop"] as? String
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            var payload: [String: Any] = ["chat": chat]
            if let loop { payload["loop"] = loop }
            NotificationCenter.default.post(name: .weftOpenConversation, object: nil, userInfo: payload)
        }
    }
}

extension Notification.Name {
    /// A notification banner was clicked: open this conversation.
    static let weftOpenConversation = Notification.Name("weftOpenConversation")
}
