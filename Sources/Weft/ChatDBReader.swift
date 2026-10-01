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
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Messages/chat.db")
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
                     WHERE j2.chat_id = c.ROWID ORDER BY mm.date DESC, mm.ROWID DESC LIMIT 1)
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
                lastSnippet: snippet
            )
        }
    }

    /// Full transcript of one conversation, oldest first (UI shows oldest at top).
    /// - Parameter after: when set, only messages with ROWID greater than this are returned (polling).
    func fetchMessages(chatRowID: Int64, after: Int64? = nil) throws -> [ChatMessage] {
        var sql = """
            SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, m.date,
                   COALESCE(h.id, ''), m.cache_has_attachments
              FROM message m
              JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
             WHERE cmj.chat_id = ?
               AND m.associated_message_guid IS NULL
            """
        // Skip tapbacks / reactions / threaded-reply metadata rows; they carry
        // associated_message_guid and would pollute the transcript.
        if after != nil { sql += " AND m.ROWID > ?" }
        sql += " ORDER BY m.date ASC, m.ROWID ASC"

        return try query(sql, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, chatRowID)
            if let after { sqlite3_bind_int64(stmt, 2, after) }
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
                handleId: columnString(stmt, 5) ?? ""
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
