import Foundation

// MARK: - ChatMessage

/// One row from the iMessage `message` table (~/Library/Messages/chat.db).
struct ChatMessage: Identifiable, Sendable, Hashable {
    /// message.ROWID — the stable identity we use for stitching topics.
    let id: Int64
    let text: String
    let isFromMe: Bool
    let date: Date
    /// Phone number or email of the other participant ("" when unknown).
    let handleId: String
    /// message.guid — what reactions point at.
    var guid: String = ""
    /// Reactions (tapbacks / emoji) currently attached to this message.
    var reactions: [Reaction] = []
    /// Contact name (or number) of whoever sent it; empty for your own.
    var senderName: String = ""
    /// Photos, videos and files sent with it.
    var attachments: [Attachment] = []

    /// Label used in transcripts sent to the AI: "You", the sender's name
    /// (group chats, known contacts), or "Them".
    var speaker: String {
        if isFromMe { return "You" }
        return senderName.isEmpty ? "Them" : senderName
    }

    /// iMessage stores `message.date` as INTEGER nanoseconds since the Cocoa
    /// epoch (2001-01-01 00:00:00 UTC). 978307200 is the number of seconds
    /// between the Unix epoch (1970) and the Cocoa epoch (2001).
    static func dateFromAppleTimestamp(_ nanos: Int64) -> Date {
        Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000 + 978307200)
    }
}

// MARK: - Attachment

/// A file sent with a message (from Messages' attachment table).
struct Attachment: Sendable, Hashable, Identifiable {
    let id: Int64
    /// Full path on this Mac (Messages stores "~/Library/Messages/Attachments/…").
    let path: String
    let mime: String
    let name: String
    let bytes: Int64

    var url: URL { URL(fileURLWithPath: path) }
    var isImage: Bool { mime.hasPrefix("image/") }
    var isVideo: Bool { mime.hasPrefix("video/") }
    /// Not on this Mac yet (still in iCloud).
    var isMissing: Bool { !FileManager.default.fileExists(atPath: path) }
}

// MARK: - Reaction

/// A tapback or emoji reaction on a message. Messages stores each one as its
/// own row pointing at the target message's guid.
struct Reaction: Sendable, Hashable {
    let emoji: String
    let isFromMe: Bool
    /// Who reacted (handle); "" for you. Groups can have several people
    /// reacting to the same message.
    var sender: String = ""
}

/// One reaction row as read from the database: an add or a removal.
struct ReactionEvent: Sendable {
    let rowID: Int64
    let targetGuid: String
    let emoji: String
    let isFromMe: Bool
    let isRemoval: Bool
    /// Who reacted (handle); "" for you.
    var sender: String = ""

    /// associated_message_type: 2000–2007 add, 3000–3007 remove the same kind.
    /// 2006 is an any-emoji reaction (the emoji is in associated_message_emoji).
    static func emoji(forType type: Int64, custom: String?) -> String? {
        switch type % 1000 {
        case 0: return "❤️"
        case 1: return "👍"
        case 2: return "👎"
        case 3: return "😂"
        case 4: return "‼️"
        case 5: return "❓"
        case 6: return (custom?.isEmpty == false) ? custom : nil
        default: return nil
        }
    }

    /// "p:0/GUID" or "bp:GUID" → "GUID".
    static func targetGuid(from associated: String) -> String {
        if let slash = associated.lastIndex(of: "/") {
            return String(associated[associated.index(after: slash)...])
        }
        if let colon = associated.firstIndex(of: ":") {
            return String(associated[associated.index(after: colon)...])
        }
        return associated
    }
}

// MARK: - ChatInfo

/// One conversation from the `chat` table, for the conversation picker.
struct ChatInfo: Identifiable, Sendable, Hashable {
    /// chat.ROWID — persisted in UserDefaults once the user picks it.
    let id: Int64
    /// Comma-joined participant handle ids (phone/email).
    let participants: String
    let messageCount: Int
    let lastDate: Date?
    let lastSnippet: String?
    /// chat.guid — Messages' own id for the conversation; used to send to a
    /// whole group chat.
    var guid: String = ""
    /// "iMessage" or "SMS".
    var service: String = ""
}

// MARK: - Topic

/// One LLM-derived segment of the conversation. `messageIds` are message
/// ROWIDs in ascending chronological order.
struct Topic: Identifiable, Sendable, Hashable, Codable {
    let id: UUID
    var title: String
    var summary: String
    var messageIds: [Int64]
}

// MARK: - OpenLoop

enum LoopStatus: String, Sendable, Codable, CaseIterable {
    case open
    case resolved
    case dismissed
}

/// A user request with no confirmed resolution, or an assistant promise with
/// no confirmed completion, as detected by the LLM.
struct OpenLoop: Identifiable, Sendable, Hashable, Codable {
    let id: UUID
    var title: String
    var detail: String
    var status: LoopStatus
    var createdDate: Date
    /// The message the loop came from (chat.db ROWID), when known.
    var sourceMessageId: Int64? = nil
    /// Raised while sorting old history: still needs checking against the
    /// later conversation, which may have resolved it.
    var needsLaterCheck: Bool? = nil
    /// Who it's waiting on.
    var owner: LoopOwner? = nil
    /// When it's due (a reminder fires then).
    var dueDate: Date? = nil
    /// Hidden from the active list until then (a reminder fires then).
    var snoozedUntil: Date? = nil

    /// Same follow-up: same title AND from the same message (when known).
    func matches(_ other: OpenLoop) -> Bool {
        guard title.caseInsensitiveCompare(other.title) == .orderedSame else { return false }
        guard let a = sourceMessageId, let b = other.sourceMessageId else { return true }
        return a == b
    }

    func isSnoozed(at now: Date = Date()) -> Bool { (snoozedUntil ?? .distantPast) > now }
    func isOverdue(at now: Date = Date()) -> Bool {
        guard status == .open, let dueDate else { return false }
        return dueDate < Calendar.current.startOfDay(for: now)
    }
}

/// Who a follow-up is waiting on.
enum LoopOwner: String, Codable, Sendable, CaseIterable {
    /// You asked, or someone promised you something.
    case them
    /// Someone asked you, or you promised something.
    case me

    var label: String { self == .them ? "Waiting on them" : "Owed by me" }

    /// AI replies: "me" / "them" (anything else → nil).
    static func parse(_ s: String?) -> LoopOwner? { s.flatMap { LoopOwner(rawValue: $0.lowercased()) } }
}

enum DueDateParser {
    /// "YYYY-MM-DD" from the AI → that day at 9:00 local time.
    static func parse(_ s: String?) -> Date? {
        guard let s, s.count >= 10 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let day = f.date(from: String(s.prefix(10))) else { return nil }
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)
    }
}

// MARK: - Sidebar selection

enum SidebarSelection: Hashable {
    case all
    case topic(UUID)
    case loop(UUID)
}
