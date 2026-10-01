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

    /// iMessage stores `message.date` as INTEGER nanoseconds since the Cocoa
    /// epoch (2001-01-01 00:00:00 UTC). 978307200 is the number of seconds
    /// between the Unix epoch (1970) and the Cocoa epoch (2001).
    static func dateFromAppleTimestamp(_ nanos: Int64) -> Date {
        Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000 + 978307200)
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
}

// MARK: - Sidebar selection

enum SidebarSelection: Hashable {
    case all
    case topic(UUID)
    case loop(UUID)
}
