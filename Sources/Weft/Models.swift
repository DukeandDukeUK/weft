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
}

// MARK: - Sidebar selection

enum SidebarSelection: Hashable {
    case all
    case topic(UUID)
    case loop(UUID)
}
