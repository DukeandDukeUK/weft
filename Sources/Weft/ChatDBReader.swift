import Foundation
import SQLite3

// MARK: - AttributedBodyParser

/// `message.attributedBody` is a BLOB holding a binary-plist NSKeyedArchiver
/// of an NSAttributedString. `message.text` is NULL for rich-text messages
/// (and for tapbacks/reactions), so we need this to recover their content.
enum AttributedBodyParser {
    static func string(from data: Data) -> String? {
        // 1) Proper decode: the archive's top object is an (mutable)
        //    attributed string whose backing store is NSString.
        do {
            let classes: [AnyClass] = [
                NSAttributedString.self,
                NSMutableAttributedString.self,
                NSString.self,
                NSMutableString.self,
            ]
            if let attr = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? NSAttributedString {
                let s = attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { return s }
            }
        } catch {
            // Fall through to the heuristic below.
        }
        // 2) Heuristic fallback: the bplist usually embeds the raw string, so
        //    a lossy UTF-8 decode plus "longest printable run" recovers it.
        return longestPrintableRun(in: data)
    }

    /// Visible so it can be unit-tested on platforms without NSKeyedUnarchiver data.
    static func longestPrintableRun(in data: Data) -> String? {
        let lossy = String(decoding: data, as: UTF8.self) // invalid bytes -> U+FFFD
        var best: String?
        for piece in lossy.split(separator: "�") {
            let t = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count > 3, t.rangeOfCharacter(from: .letters) != nil else { continue }
            if t.count > (best?.count ?? 0) { best = t }
        }
        return best
    }
}

// MARK: - ChatDBReader

/// All SQLite access to ~/Library/Messages/chat.db.
///
/// An actor so the OpaquePointer handle can never be touched from two threads
/// at once (Swift 6 data-race safety). The database is always opened
/// READ-ONLY and closed after each operation — nothing is ever written.
///
/// Requires the user to grant Full Disk Access to the app; without it the
/// open fails with SQLITE_CANTOPEN and we surface a human-readable error.
actor ChatDBReader {
    static let shared = ChatDBReader()

    /// Tests use a small fixture database; the app always reads Messages'.
    private let pathOverride: String?
    init(path: String? = nil) { pathOverride = path }

    /// Decoded rich-text bodies (messages whose text is only in
    /// attributedBody), kept for the session so repeat searches are fast.
    private var decodedText: [Int64: String] = [:]

    enum ReaderError: Error, LocalizedError {
        case noDatabase
        case accessDenied(String)
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDatabase:
                return "No Messages database found at ~/Library/Messages/chat.db. Is the Messages app set up and signed in on this Mac?"
            case .accessDenied(let why):
                return "Could not read the Messages database (\(why)). Grant Full Disk Access in System Settings > Privacy & Security > Full Disk Access."
            case .queryFailed(let why):
                return "Messages database query failed: \(why)"
            }
        }
    }

    private var dbPath: String {
        pathOverride ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Messages/chat.db")
    }

    enum Access: Sendable {
        case ok
        /// macOS is blocking the Messages folder: Full Disk Access not granted.
        case noPermission
        /// Genuinely no Messages history on this Mac.
        case missing
    }

    /// Tells "not allowed to look" apart from "nothing there". Without Full
    /// Disk Access the Messages folder can't even be listed, which would
    /// otherwise look like a missing database.
    func checkAccess() -> Access {
        let folder = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Messages")
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder)
        } catch let error as NSError {
            let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
            if error.code == NSFileReadNoPermissionError || posix == Int(EPERM) || posix == Int(EACCES) {
                return .noPermission
            }
            return .missing
        }
        guard databaseExists() else { return .missing }
        do {
            let db = try open()
            sqlite3_close(db)
            return .ok
        } catch {
            return .noPermission
        }
    }

    func databaseExists() -> Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    /// True when we can actually open the database — i.e. Full Disk Access
    /// is granted (and the database exists).
    func fullDiskAccessOK() -> Bool {
        guard databaseExists() else { return false }
        do {
            let db = try open()
            sqlite3_close(db)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Public queries

    /// Every non-empty conversation, newest first, for the picker.
    func listChats() throws -> [ChatInfo] {
        let sql = """
            SELECT c.ROWID,
                   COALESCE(GROUP_CONCAT(DISTINCT h.id), ''),
                   COUNT(DISTINCT m.ROWID),
                   MAX(m.date),
                   (SELECT mm.text FROM message mm
                      JOIN chat_message_join j2 ON j2.message_id = mm.ROWID
                     WHERE j2.chat_id = c.ROWID ORDER BY mm.date DESC, mm.ROWID DESC LIMIT 1),
                   (SELECT mm.attributedBody FROM message mm
                      JOIN chat_message_join j2 ON j2.message_id = mm.ROWID
                     WHERE j2.chat_id = c.ROWID ORDER BY mm.date DESC, mm.ROWID DESC LIMIT 1),
                   c.guid,
                   COALESCE(c.service_name, '')
              FROM chat c
            LEFT JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
            LEFT JOIN handle h ON h.ROWID = chj.handle_id
            LEFT JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            LEFT JOIN message m ON m.ROWID = cmj.message_id
             GROUP BY c.ROWID
            HAVING COUNT(DISTINCT m.ROWID) > 0
             ORDER BY MAX(m.date) DESC
            """
        return try query(sql, bind: { _ in }) { stmt in
            let rowID = columnInt64(stmt, 0)
            let participants = columnString(stmt, 1) ?? ""
            let count = Int(columnInt64(stmt, 2))
            let lastDate: Date? = columnIsNull(stmt, 3) ? nil : ChatMessage.dateFromAppleTimestamp(columnInt64(stmt, 3))
            var snippet = columnString(stmt, 4) ?? ""
            if snippet.isEmpty, let blob = columnBlob(stmt, 5) {
                snippet = AttributedBodyParser.string(from: blob) ?? ""
            }
            return ChatInfo(
                id: rowID,
                participants: participants,
                messageCount: count,
                lastDate: lastDate,
                lastSnippet: snippet,
                guid: columnString(stmt, 6) ?? "",
                service: columnString(stmt, 7) ?? ""
            )
        }
    }

    /// Full transcript of one conversation, oldest first (UI shows oldest at top).
    /// - Parameter after: when set, only messages with ROWID greater than this are returned (polling).
    /// - Parameters:
    ///   - upTo: when set, only messages with ROWID up to and including this.
    ///   - newest: when set, only the newest N matching messages (still returned oldest first).
    func fetchMessages(chatRowID: Int64, after: Int64? = nil, upTo: Int64? = nil, newest: Int? = nil) throws -> [ChatMessage] {
        var sql = """
            SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, m.date,
                   COALESCE(h.id, ''), m.cache_has_attachments, m.guid
              FROM message m
              JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
             WHERE cmj.chat_id = ?
               AND m.associated_message_guid IS NULL
            """
        // Skip tapbacks / reactions / threaded-reply metadata rows; they carry
        // associated_message_guid and would pollute the transcript.
        if after != nil { sql += " AND m.ROWID > ?" }
        if upTo != nil { sql += " AND m.ROWID <= ?" }
        if newest != nil {
            sql += " ORDER BY m.date DESC, m.ROWID DESC LIMIT ?"
        } else {
            sql += " ORDER BY m.date ASC, m.ROWID ASC"
        }

        let rows: [ChatMessage] = try query(sql, bind: { stmt in
            var i: Int32 = 1
            sqlite3_bind_int64(stmt, i, chatRowID); i += 1
            if let after { sqlite3_bind_int64(stmt, i, after); i += 1 }
            if let upTo { sqlite3_bind_int64(stmt, i, upTo); i += 1 }
            if let newest { sqlite3_bind_int64(stmt, i, Int64(newest)) }
        }) { stmt in
            let rowID = columnInt64(stmt, 0)
            var text = columnString(stmt, 1)
            if (text ?? "").isEmpty, let blob = columnBlob(stmt, 2) {
                text = AttributedBodyParser.string(from: blob)
            }
            let hasAttachments = columnInt64(stmt, 6) != 0
            let final = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !final.isEmpty || hasAttachments else { return nil } // drop empty/system rows
            let dateValue = columnInt64(stmt, 4)
            return ChatMessage(
                id: rowID,
                text: final.isEmpty ? "[attachment]" : final,
                isFromMe: columnInt64(stmt, 3) != 0,
                date: ChatMessage.dateFromAppleTimestamp(dateValue),
                handleId: columnString(stmt, 5) ?? "",
                guid: columnString(stmt, 7) ?? ""
            )
        }
        return newest != nil ? rows.reversed() : rows
    }

    /// Search several conversations at once, newest first. Plain-text
    /// messages are matched in SQL; messages whose text is stored only as
    /// rich text are decoded first and then matched (the raw stored bytes
    /// can't be searched reliably).
    func search(_ text: String, inChats chats: [Int64], limit: Int = 200) throws -> [(chat: Int64, message: ChatMessage)] {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !chats.isEmpty else { return [] }
        let escaped = q.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        let placeholders = Array(repeating: "?", count: chats.count).joined(separator: ",")
        let columns = """
            SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, m.date,
                   COALESCE(h.id, ''), m.cache_has_attachments, m.guid, cmj.chat_id
              FROM message m
              JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
             WHERE cmj.chat_id IN (\(placeholders))
               AND m.associated_message_guid IS NULL
            """
        func row(_ stmt: OpaquePointer?, body: String) -> (Int64, ChatMessage) {
            (columnInt64(stmt, 8), ChatMessage(
                id: columnInt64(stmt, 0), text: body, isFromMe: columnInt64(stmt, 3) != 0,
                date: ChatMessage.dateFromAppleTimestamp(columnInt64(stmt, 4)),
                handleId: columnString(stmt, 5) ?? "", guid: columnString(stmt, 7) ?? ""
            ))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // 1. Plain text: SQL does the matching.
        var hits: [(Int64, ChatMessage)] = try query(columns + " AND m.text LIKE ? ESCAPE '\\' ORDER BY m.date DESC LIMIT ?", bind: { stmt in
            var i: Int32 = 1
            for c in chats { sqlite3_bind_int64(stmt, i, c); i += 1 }
            sqlite3_bind_text(stmt, i, pattern, -1, transient); i += 1
            sqlite3_bind_int64(stmt, i, Int64(limit))
        }) { stmt in
            guard let body = columnString(stmt, 1), body.localizedCaseInsensitiveContains(q) else { return nil }
            return row(stmt, body: body)
        }

        // 2. Rich text only: decode (once per session), then match.
        var cache = decodedText
        let rich: [(Int64, ChatMessage)] = try query(columns + " AND (m.text IS NULL OR m.text = '') AND m.attributedBody IS NOT NULL", bind: { stmt in
            var i: Int32 = 1
            for c in chats { sqlite3_bind_int64(stmt, i, c); i += 1 }
        }) { stmt in
            let id = columnInt64(stmt, 0)
            let body: String
            if let known = cache[id] {
                body = known
            } else {
                guard let blob = columnBlob(stmt, 2) else { return nil }
                body = AttributedBodyParser.string(from: blob) ?? ""
                cache[id] = body
            }
            guard body.localizedCaseInsensitiveContains(q) else { return nil }
            return row(stmt, body: body)
        }
        decodedText = cache
        hits.append(contentsOf: rich)
        return Array(hits.sorted { $0.1.date > $1.1.date }.prefix(limit)).map { (chat: $0.0, message: $0.1) }
    }

    /// Attachments in a conversation, by message ROWID. Skips link-preview
    /// data and attachments Messages itself hides.
    func fetchAttachments(chatRowID: Int64, after: Int64 = 0) throws -> [Int64: [Attachment]] {
        let sql = """
            SELECT maj.message_id, a.ROWID, a.filename, COALESCE(a.mime_type, ''),
                   COALESCE(a.transfer_name, ''), COALESCE(a.total_bytes, 0)
              FROM attachment a
              JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
              JOIN chat_message_join cmj ON cmj.message_id = maj.message_id
             WHERE cmj.chat_id = ? AND maj.message_id > ?
               AND COALESCE(a.hide_attachment, 0) = 0
               AND a.filename IS NOT NULL
               AND a.filename NOT LIKE '%.pluginPayloadAttachment'
            """
        let home = NSHomeDirectory()
        let rows: [(Int64, Attachment)] = try query(sql, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, chatRowID)
            sqlite3_bind_int64(stmt, 2, after)
        }) { stmt in
            guard let raw = columnString(stmt, 2) else { return nil }
            let path = raw.hasPrefix("~") ? home + raw.dropFirst() : raw
            let name = columnString(stmt, 4).flatMap { $0.isEmpty ? nil : $0 } ?? (path as NSString).lastPathComponent
            return (columnInt64(stmt, 0), Attachment(id: columnInt64(stmt, 1), path: path, mime: columnString(stmt, 3) ?? "", name: name, bytes: columnInt64(stmt, 5)))
        }
        return Dictionary(grouping: rows, by: \.0).mapValues { $0.map(\.1) }
    }

    /// Newest real message (not a reaction) in a conversation — for the
    /// "new messages" dot on conversations you aren't looking at.
    func latestMessageRowID(chatRowID: Int64) throws -> Int64 {
        let sql = """
            SELECT COALESCE(MAX(m.ROWID), 0)
              FROM message m
              JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
             WHERE cmj.chat_id = ? AND m.associated_message_guid IS NULL
            """
        return try query(sql, bind: { sqlite3_bind_int64($0, 1, chatRowID) }) { columnInt64($0, 0) }.first ?? 0
    }

    /// Incoming messages (not yours, not reactions) newer than `after` — the
    /// count shown on a conversation and the Dock badge.
    func countIncoming(chatRowID: Int64, after: Int64) throws -> Int {
        let sql = """
            SELECT COUNT(*)
              FROM message m
              JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
             WHERE cmj.chat_id = ? AND m.ROWID > ?
               AND m.is_from_me = 0 AND m.associated_message_guid IS NULL
            """
        return try query(sql, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, chatRowID)
            sqlite3_bind_int64(stmt, 2, after)
        }) { Int(columnInt64($0, 0)) }.first ?? 0
    }

    /// The last `limit` messages up to and including `upTo`, oldest first —
    /// context for filing new messages in the background.
    func fetchContext(chatRowID: Int64, upTo: Int64, limit: Int) throws -> [ChatMessage] {
        try fetchMessages(chatRowID: chatRowID, upTo: upTo, newest: limit)
    }

    /// Reaction rows (adds and removals) in this conversation, oldest first.
    /// - Parameter after: only rows with ROWID greater than this (polling).
    func fetchReactions(chatRowID: Int64, after: Int64 = 0) throws -> [ReactionEvent] {
        let sql = """
            SELECT m.ROWID, m.associated_message_guid, m.associated_message_type,
                   m.associated_message_emoji, m.is_from_me, COALESCE(h.id, '')
              FROM message m
              JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
             WHERE cmj.chat_id = ?
               AND m.ROWID > ?
               AND m.associated_message_guid IS NOT NULL
               AND ((m.associated_message_type BETWEEN 2000 AND 2007)
                 OR (m.associated_message_type BETWEEN 3000 AND 3007))
             ORDER BY m.date ASC, m.ROWID ASC
            """
        return try query(sql, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, chatRowID)
            sqlite3_bind_int64(stmt, 2, after)
        }) { stmt in
            let type = columnInt64(stmt, 2)
            guard let associated = columnString(stmt, 1),
                  let emoji = ReactionEvent.emoji(forType: type, custom: columnString(stmt, 3)) else { return nil }
            return ReactionEvent(
                rowID: columnInt64(stmt, 0),
                targetGuid: ReactionEvent.targetGuid(from: associated),
                emoji: emoji,
                isFromMe: columnInt64(stmt, 4) != 0,
                isRemoval: type >= 3000,
                sender: columnInt64(stmt, 4) != 0 ? "" : (columnString(stmt, 5) ?? "")
            )
        }
    }

    // MARK: - Low-level helpers

    private func open() throws -> OpaquePointer {
        guard databaseExists() else { throw ReaderError.noDatabase }
        var db: OpaquePointer?
        let rc = dbPath.withCString { cPath in
            sqlite3_open_v2(cPath, &db, SQLITE_OPEN_READONLY, nil)
        }
        guard rc == SQLITE_OK, let db else {
            let why = (rc == SQLITE_CANTOPEN)
                ? "macOS blocked access — Full Disk Access is not granted"
                : "SQLite open error \(rc)"
            throw ReaderError.accessDenied(why)
        }
        return db
    }

    private func query<T>(
        _ sql: String,
        bind: (OpaquePointer?) -> Void,
        row: (OpaquePointer?) -> T?
    ) throws -> [T] {
        let db = try open()
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown error"
            throw ReaderError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let value = row(stmt) { out.append(value) }
        }
        return out
    }

    private func columnIsNull(_ stmt: OpaquePointer?, _ index: Int32) -> Bool {
        sqlite3_column_type(stmt, index) == SQLITE_NULL
    }

    private func columnInt64(_ stmt: OpaquePointer?, _ index: Int32) -> Int64 {
        sqlite3_column_int64(stmt, index)
    }

    private func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard !columnIsNull(stmt, index), let p = sqlite3_column_text(stmt, index) else { return nil }
        return p.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }

    private func columnBlob(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        guard !columnIsNull(stmt, index), let p = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0 else { return nil }
        return Data(bytes: p, count: count)
    }
}
