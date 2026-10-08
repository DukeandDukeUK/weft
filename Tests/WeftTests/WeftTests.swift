import XCTest
import SQLite3
@testable import Weft

/// Regression tests for bugs found in review. None of them read or send
/// real messages: the AI is replaced by scripted replies, and saved data
/// goes to a scratch folder.
@MainActor
final class WeftTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("weft-tests-\(UUID().uuidString)")
        SegmentationCache.directoryOverride = scratch
        TokenLog.fileOverride = scratch.appendingPathComponent("token-log.json")
        AppSettings.shared.provider = .claude
    }

    override func tearDown() async throws {
        LLMClient.testResponder = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    private func msg(_ id: Int64, _ text: String = "hello", me: Bool = false) -> ChatMessage {
        ChatMessage(id: id, text: text, isFromMe: me, date: Date(timeIntervalSince1970: Double(id) * 60), handleId: me ? "" : "x")
    }

    /// Scripted AI: picks a reply by which job the prompt is for.
    private func script(topics: String = #"[{"title":"Alpha","summary":"s","ranges":[[0,9]]}]"#,
                        followUps: String = "[]",
                        later: String = #"{"resolved":[]}"#,
                        delay: UInt64 = 0) {
        LLMClient.testResponder = { system, _ in
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            if system.contains("organizing a chat transcript") { return topics }
            if system.contains("open items from earlier") { return later }
            if system.contains("reviewing a chat transcript") { return followUps }
            return #"{"assignments":[]}"#
        }
    }

    // #2 — switching conversations during a sort must not save A's result into B.
    func testSwitchingConversationDiscardsSlowSort() async throws {
        script(delay: 300_000_000)
        let vm = WeftViewModel()
        vm.settings.selectedChatRowID = 101
        vm.settings.grantConsent(101)
        vm.messages = [msg(1), msg(2)]
        let sort = Task { await vm.analyze() }
        try await Task.sleep(nanoseconds: 50_000_000)
        // The user opens conversation 202 while the AI is still working.
        vm.startNewSession()
        vm.settings.selectedChatRowID = 202
        vm.messages = []
        vm.topics = []
        await sort.value
        XCTAssertTrue(vm.topics.isEmpty, "A's topics leaked into B's window")
        XCTAssertNil(SegmentationCache.load(chatId: 202), "A's result was saved as B")
        XCTAssertNil(SegmentationCache.load(chatId: 101), "a discarded result was still saved")
    }

    // #3 — the saved checkpoint never passes a message still waiting to be filed.
    func testCheckpointStopsBeforePendingMessage() {
        let messages = [msg(1), msg(2), msg(3)]
        XCTAssertEqual(WeftViewModel.checkpoint(messages: messages, pending: [2]), 1)
        XCTAssertEqual(WeftViewModel.checkpoint(messages: messages, pending: []), 3)
    }

    // #4 — an unreadable follow-up reply is an error, not "nothing outstanding".
    func testMalformedFollowUpReplyThrows() async {
        LLMClient.testResponder = { _, _ in "sorry, I can't do JSON today" }
        let client = LLMClient(provider: .claude, model: "x")
        do {
            _ = try await OpenLoopDetector(client: client).detect(messages: [msg(1, "can you book it?", me: true)])
            XCTFail("expected an error")
        } catch {}
    }

    // #5 — re-sort closes old follow-ups the later conversation settled, and
    // never touches ones you marked yourself.
    func testResortReconcilesOldFollowUps() async {
        script(followUps: "[]", later: #"{"resolved":[0]}"#)
        let vm = WeftViewModel()
        vm.settings.selectedChatRowID = 303
        vm.settings.grantConsent(303)
        vm.messages = (1...10).map { msg(Int64($0)) }
        let open = OpenLoop(id: UUID(), title: "Book dentist", detail: "", status: .open, createdDate: Date(), sourceMessageId: 2)
        let dismissed = OpenLoop(id: UUID(), title: "Old idea", detail: "", status: .dismissed, createdDate: Date(), sourceMessageId: 3)
        vm.loops = [open, dismissed]
        await vm.analyze()
        XCTAssertEqual(vm.loops.first { $0.id == open.id }?.status, .resolved)
        XCTAssertEqual(vm.loops.first { $0.id == dismissed.id }?.status, .dismissed)
    }

    // #6 — one thread per message, even if the AI assigns a message twice.
    func testFilerGivesEachMessageOneThread() throws {
        let raw = #"{"assignments":[{"start":0,"end":1,"topic":0},{"start":1,"end":2,"topic":1}],"newLoops":[],"resolvedLoops":[]}"#
        let topics = [Topic(id: UUID(), title: "A", summary: "", messageIds: [100]),
                      Topic(id: UUID(), title: "B", summary: "", messageIds: [101])]
        let r = try TopicFiler.parse(raw, newMessages: [msg(1), msg(2), msg(3)], topics: topics, openLoops: [])
        let all = r.assignments.flatMap(\.messageIds)
        XCTAssertEqual(all.sorted(), [1, 2, 3])
        XCTAssertEqual(Set(all).count, all.count, "a message landed in two threads")
    }

    // #7 — new-message filing respects each AI's size limit.
    func testNewMessageBatchesStayWithinLimits() {
        let long = (1...100).map { msg(Int64($0), String(repeating: "x", count: 2_000)) }
        let local = WeftViewModel.batch(long, local: true)
        XCTAssertLessThanOrEqual(local.reduce(0) { $0 + min($1.text.count, 2_000) + 40 }, 8_000 + 2_040)
        XCTAssertEqual(local.first?.id, 1, "oldest first")
        let cloud = WeftViewModel.batch(long, local: false)
        XCTAssertLessThanOrEqual(cloud.count, 120)
    }

    // Full sort: a subject the conversation returns to stays one topic.
    func testFullSortKeepsReturningSubjectTogether() throws {
        let raw = #"[{"title":"Flight","summary":"","ranges":[[0,1],[4,5]]},{"title":"Dentist","summary":"","ranges":[[2,3]]},{"title":"flight","summary":"","ranges":[[6,6]]}]"#
        let topics = try TopicSegmenter.parseTopics(from: raw, messages: (1...8).map { msg(Int64($0)) })
        XCTAssertEqual(topics.count, 2)
        XCTAssertEqual(topics.first { $0.title == "Flight" }?.messageIds, [1, 2, 5, 6, 7, 8])
    }

    // Stray text after a reply (e.g. "</final>") is ignored.
    func testReplyWithTrailingTagStillParses() {
        XCTAssertEqual(TopicSegmenter.stripFences(#"{"a":"x}y"}</final>"#), #"{"a":"x}y"}"#)
    }

    // Drafts belong to their conversation.
    func testDraftsArePerConversation() {
        let vm = WeftViewModel()
        vm.settings.selectedChatRowID = 1
        vm.currentDraft = "for Alice"
        vm.settings.selectedChatRowID = 2
        XCTAssertEqual(vm.currentDraft, "")
        vm.currentDraft = "for Bob"
        vm.settings.selectedChatRowID = 1
        XCTAssertEqual(vm.currentDraft, "for Alice")
        vm.drafts = [:]
    }

    // First sort waits for consent, and consent is remembered (per destination).
    func testFirstSortConsent() {
        let vm = WeftViewModel()
        let chat = ChatInfo(id: 404, participants: "x", messageCount: 1, lastDate: nil, lastSnippet: nil)
        vm.firstSortRequest = chat
        vm.approveFirstSort()
        XCTAssertNil(vm.firstSortRequest)
        XCTAssertTrue(vm.settings.hasConsent(404, for: .claude))
    }

    // MARK: - 0.2.0 features

    func testTopicEditing() {
        let a = Topic(id: UUID(), title: "Flight", summary: "", messageIds: [1, 2, 3, 4])
        let b = Topic(id: UUID(), title: "Dentist", summary: "", messageIds: [5, 6])
        var t = TopicEditor.rename([a, b], a.id, to: "  Denver trip ")
        XCTAssertEqual(t.first { $0.id == a.id }?.title, "Denver trip")
        t = TopicEditor.move([a, b], messages: [2], to: b.id)
        XCTAssertEqual(t.first { $0.id == b.id }?.messageIds, [2, 5, 6])
        XCTAssertEqual(t.first { $0.id == a.id }?.messageIds, [1, 3, 4])
        t = TopicEditor.merge([a, b], b.id, into: a.id)
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[0].messageIds, [1, 2, 3, 4, 5, 6])
        let split = TopicEditor.split([a, b], a.id, from: 3, newTitle: "Flight (continued)")
        XCTAssertEqual(split.topics.first { $0.id == a.id }?.messageIds, [1, 2])
        XCTAssertEqual(split.topics.first { $0.id == split.newID }?.messageIds, [3, 4])
        // Splitting at the first message would just rename: refused.
        XCTAssertNil(TopicEditor.split([a, b], a.id, from: 1, newTitle: "x").newID)
        // Moving a topic's last message out removes the empty topic.
        XCTAssertEqual(TopicEditor.move([a, b], messages: [5, 6], to: a.id).count, 1)
    }

    func testTopicEditUndoAndRedo() {
        let vm = WeftViewModel()
        vm.settings.selectedChatRowID = 505
        let a = Topic(id: UUID(), title: "Flight", summary: "", messageIds: [1, 2])
        vm.topics = [a]
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        vm.editTopics("Rename Topic", undoManager: undo) { TopicEditor.rename($0, a.id, to: "Denver") }
        undo.endUndoGrouping()
        XCTAssertEqual(vm.topics[0].title, "Denver")
        undo.undo()
        XCTAssertEqual(vm.topics[0].title, "Flight")
        undo.redo()
        XCTAssertEqual(vm.topics[0].title, "Denver")
        XCTAssertEqual(SegmentationCache.load(chatId: 505)?.topics.first?.title, "Denver", "edits are saved")
    }

    func testFollowUpOwnerAndDueDateFromAI() throws {
        let raw = #"{"assignments":[{"start":0,"end":1,"topic":0}],"newLoops":[{"title":"Send the deck","detail":"You promised the deck","message":0,"owner":"me","due":"2026-10-09"},{"title":"Hold flight","detail":"They'll hold it","message":1,"owner":"them"}],"resolvedLoops":[]}"#
        let r = try TopicFiler.parse(raw, newMessages: [msg(1, "I'll send the deck by Friday", me: true), msg(2, "I'll hold the flight")],
                                     topics: [Topic(id: UUID(), title: "Work", summary: "", messageIds: [0])], openLoops: [])
        XCTAssertEqual(r.newLoops.first { $0.title == "Send the deck" }?.owner, .me)
        XCTAssertEqual(r.newLoops.first { $0.title == "Hold flight" }?.owner, .them)
        let due = try XCTUnwrap(r.newLoops.first { $0.title == "Send the deck" }?.dueDate)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: due)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour], [2026, 10, 9, 9])
    }

    func testSnoozeAndOverdue() {
        let now = Date()
        var loop = OpenLoop(id: UUID(), title: "x", detail: "", status: .open, createdDate: now)
        loop.snoozedUntil = now.addingTimeInterval(3600)
        XCTAssertTrue(loop.isSnoozed(at: now))
        XCTAssertFalse(loop.isSnoozed(at: now.addingTimeInterval(7200)), "snooze ends")
        loop.dueDate = now.addingTimeInterval(-3 * 86_400)
        XCTAssertTrue(loop.isOverdue(at: now))
        loop.status = .resolved
        XCTAssertFalse(loop.isOverdue(at: now), "done items are never overdue")
    }

    func testPausedConversationSendsNothing() async throws {
        var calls = 0
        LLMClient.testResponder = { _, _ in calls += 1; return #"{"assignments":[]}"# }
        let vm = WeftViewModel()
        vm.settings.selectedChatRowID = 606
        vm.settings.pausedChats.insert(606)
        defer { vm.settings.pausedChats.remove(606) }
        vm.messages = [msg(1), msg(2)]
        vm.topics = [Topic(id: UUID(), title: "A", summary: "", messageIds: [1])]
        vm.pendingMessageIDs = [2]
        vm.retryFiling()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(calls, 0, "a paused conversation was sent to the AI")
        XCTAssertEqual(vm.pendingMessageIDs, [2], "the new message should still be waiting")
    }

    // MARK: - 0.2.1 fixes

    // "Not Now" really means nothing is sent — even when new messages arrive.
    func testNotNowBlocksEveryAICall() async throws {
        var calls = 0
        LLMClient.testResponder = { _, _ in calls += 1; return "[]" }
        let vm = WeftViewModel()
        vm.settings.provider = .claude
        vm.chats = [ChatInfo(id: 707, participants: "x", messageCount: 2, lastDate: nil, lastSnippet: nil)]
        vm.settings.selectedChatRowID = 707                 // never OK'd
        vm.messages = [msg(1), msg(2)]
        await vm.analyze()                                  // would be the first sort
        XCTAssertEqual(calls, 0)
        XCTAssertNotNil(vm.firstSortRequest, "should ask instead")
        vm.firstSortRequest = ChatInfo(id: 707, participants: "x", messageCount: 2, lastDate: nil, lastSnippet: nil)
        vm.postponeFirstSort()
        vm.pendingMessageIDs = [2]                          // a new message arrives
        vm.retryFiling()
        await vm.analyze()
        await vm.retryFollowUps()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(calls, 0, "something was sent after Not Now")
        XCTAssertNil(vm.firstSortRequest, "Not Now shouldn't nag on every message")
    }

    // OK'ing a local model doesn't cover a cloud AI.
    func testSwitchingFromLocalToCloudAsksAgain() async {
        var calls = 0
        LLMClient.testResponder = { _, _ in calls += 1; return "[]" }
        let vm = WeftViewModel()
        vm.chats = [ChatInfo(id: 808, participants: "x", messageCount: 1, lastDate: nil, lastSnippet: nil)]
        vm.settings.selectedChatRowID = 808
        vm.settings.grantConsent(808, for: .ollama)
        vm.settings.provider = .claude
        vm.messages = [msg(1)]
        await vm.analyze()
        XCTAssertEqual(calls, 0)
        XCTAssertNotNil(vm.firstSortRequest)
        XCTAssertTrue(vm.settings.hasConsent(808, for: .lmstudio), "another local model is the same destination")
    }

    // A snooze always wins over an earlier due date; done items never fire.
    func testReminderTime() {
        let now = Date()
        var loop = OpenLoop(id: UUID(), title: "x", detail: "", status: .open, createdDate: now)
        loop.dueDate = now.addingTimeInterval(3600)
        loop.snoozedUntil = now.addingTimeInterval(7200)
        XCTAssertEqual(Notifier.reminderDate(for: loop, now: now), loop.snoozedUntil)
        loop.snoozedUntil = nil
        XCTAssertEqual(Notifier.reminderDate(for: loop, now: now), loop.dueDate)
        loop.status = .resolved
        XCTAssertNil(Notifier.reminderDate(for: loop, now: now))
    }

    // Undo keeps messages that were filed after the edit.
    func testUndoKeepsLaterMessages() {
        let vm = WeftViewModel()
        vm.settings.selectedChatRowID = 909
        let a = Topic(id: UUID(), title: "Flight", summary: "", messageIds: [1, 2])
        let b = Topic(id: UUID(), title: "Dentist", summary: "", messageIds: [3])
        vm.topics = [a, b]
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        vm.editTopics("Merge Topics", undoManager: undo) { TopicEditor.merge($0, b.id, into: a.id) }
        undo.endUndoGrouping()
        // A new message is filed into the merged topic after the edit.
        if let i = vm.topics.firstIndex(where: { $0.id == a.id }) { vm.topics[i].messageIds.append(4) }
        undo.undo()
        XCTAssertEqual(Set(vm.topics.map(\.id)), [a.id, b.id], "merge undone")
        XCTAssertTrue(vm.topics.flatMap(\.messageIds).contains(4), "message filed after the edit was erased")
        XCTAssertEqual(vm.topics.first { $0.id == a.id }?.messageIds, [1, 2, 4])
    }

    // Two follow-ups with the same title from different messages are both kept.
    func testFollowUpsWithSameTitleFromDifferentMessages() {
        let one = OpenLoop(id: UUID(), title: "Call back", detail: "", status: .open, createdDate: Date(), sourceMessageId: 10)
        let two = OpenLoop(id: UUID(), title: "call back", detail: "", status: .open, createdDate: Date(), sourceMessageId: 20)
        let again = OpenLoop(id: UUID(), title: "Call back", detail: "", status: .open, createdDate: Date(), sourceMessageId: 10)
        XCTAssertFalse(one.matches(two))
        XCTAssertTrue(one.matches(again))
    }

    // Already-sorted conversations get consent once, at update, for the AI
    // selected then — not for whichever AI they're opened with later.
    func testLegacyConsentOnlyAtUpdate() throws {
        let d = UserDefaults.standard
        d.removeObject(forKey: "weft.legacyConsentMigrated")
        let settings = AppSettings.shared
        settings.provider = .codex
        let chat: Int64 = 1_001
        let before = settings.followedChats
        settings.followedChats = before + [chat]
        defer { settings.followedChats = before }
        try SegmentationCache.save(CachedAnalysis(messageCount: 1, newestRowId: 1, generatedAt: Date(),
            topics: [Topic(id: UUID(), title: "A", summary: "", messageIds: [1])], loops: []), chatId: chat)
        settings.migrateLegacyConsentOnce()
        XCTAssertTrue(settings.hasConsent(chat, for: .codex))
        XCTAssertFalse(settings.hasConsent(chat, for: .claude), "a different AI must ask")
        settings.provider = .claude
        settings.migrateLegacyConsentOnce()                 // runs only once
        XCTAssertFalse(settings.hasConsent(chat, for: .claude))
    }

    // MARK: - 0.2.3 fixes (Astra's 0.2.2 review)

    /// A tiny Messages-like database for tests.
    private func fixtureDB(_ rows: [(id: Int64, chat: Int64, text: String?, rich: Data?, me: Bool)]) throws -> String {
        let path = scratch.appendingPathComponent("chat-\(UUID().uuidString).db").path
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB, is_from_me INTEGER,
              date INTEGER, handle_id INTEGER, cache_has_attachments INTEGER, guid TEXT,
              associated_message_guid TEXT, associated_message_type INTEGER, associated_message_emoji TEXT);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, filename TEXT, mime_type TEXT, transfer_name TEXT, total_bytes INTEGER, hide_attachment INTEGER);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            INSERT INTO handle VALUES (1, '+15555550100');
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for r in rows {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO message VALUES (?, ?, ?, ?, ?, ?, 0, ?, NULL, 0, NULL)", -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, r.id)
            if let t = r.text { sqlite3_bind_text(stmt, 2, t, -1, transient) } else { sqlite3_bind_null(stmt, 2) }
            if let b = r.rich { _ = b.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(b.count), transient) } } else { sqlite3_bind_null(stmt, 3) }
            sqlite3_bind_int64(stmt, 4, r.me ? 1 : 0)
            sqlite3_bind_int64(stmt, 5, r.id * 1_000_000_000)
            sqlite3_bind_int64(stmt, 6, r.me ? 0 : 1)
            sqlite3_bind_text(stmt, 7, "guid-\(r.id)", -1, transient)
            sqlite3_step(stmt); sqlite3_finalize(stmt)
            sqlite3_exec(db, "INSERT INTO chat_message_join VALUES (\(r.chat), \(r.id))", nil, nil, nil)
        }
        return path
    }

    // #5 — rich-text-only messages are found by global search.
    func testSearchFindsRichTextOnlyMessages() async throws {
        let rich = try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(string: "Book the flight"), requiringSecureCoding: false)
        let path = try fixtureDB([(1, 9, nil, rich, false), (2, 9, "Plain flight note", nil, true), (3, 9, "Nothing here", nil, false)])
        let reader = ChatDBReader(path: path)
        let hits = try await reader.search("flight", inChats: [9])
        XCTAssertEqual(Set(hits.map(\.message.id)), [1, 2])
        let again = try await reader.search("book", inChats: [9])   // from the session cache
        XCTAssertEqual(again.map(\.message.id), [1])
    }

    // #6 — a bad assignment can't block a good one for the same messages.
    func testInvalidAssignmentDoesNotBlockValidOne() throws {
        let raw = #"{"assignments":[{"start":0,"end":1,"topic":99},{"start":0,"end":1,"topic":0}],"newLoops":[],"resolvedLoops":[]}"#
        let r = try TopicFiler.parse(raw, newMessages: [msg(1), msg(2)],
                                     topics: [Topic(id: UUID(), title: "A", summary: "", messageIds: [0])], openLoops: [])
        XCTAssertEqual(r.assignments.flatMap(\.messageIds), [1, 2])
    }

    // #2 — moving a message by hand while sorting is running sticks.
    func testManualMoveDuringSortSticks() async throws {
        LLMClient.testResponder = { _, _ in
            try await Task.sleep(nanoseconds: 300_000_000)
            return #"{"assignments":[{"start":0,"end":0,"topic":0}],"newLoops":[],"resolvedLoops":[]}"#
        }
        let vm = WeftViewModel()
        vm.chats = [ChatInfo(id: 1_100, participants: "x", messageCount: 3, lastDate: nil, lastSnippet: nil)]
        vm.settings.selectedChatRowID = 1_100
        vm.settings.grantConsent(1_100)
        let a = Topic(id: UUID(), title: "A", summary: "", messageIds: [1])
        let b = Topic(id: UUID(), title: "B", summary: "", messageIds: [2])
        vm.messages = [msg(1), msg(2), msg(3)]
        vm.topics = [a, b]
        vm.pendingMessageIDs = [3]
        vm.retryFiling()                                     // AI will say: 3 → A
        try await Task.sleep(nanoseconds: 100_000_000)
        vm.editTopics("Move Message", undoManager: nil) { TopicEditor.move($0, messages: [3], to: b.id) }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(vm.topics.first { $0.id == b.id }?.messageIds, [2, 3], "the AI moved it back")
        XCTAssertFalse(vm.topics.first { $0.id == a.id }?.messageIds.contains(3) ?? true)
    }

    // #3 + #4 — background sorting uses bounded batches and updates reminders.
    func testBackgroundSortingIsBatchedAndSyncsReminders() async throws {
        let chat: Int64 = 1_200
        let long = String(repeating: "word ", count: 400)   // ~2,000 characters each
        let path = try fixtureDB((1...100).map { (Int64($0), chat, long, nil, $0 % 2 == 0) })
        let settings = AppSettings.shared
        settings.provider = .ollama
        settings.setModel("test-model", for: .ollama)
        defer { settings.provider = .claude }
        settings.grantConsent(chat)
        let before = settings.followedChats
        settings.followedChats = before + [chat]
        defer { settings.followedChats = before }
        try SegmentationCache.save(CachedAnalysis(messageCount: 0, newestRowId: 0, generatedAt: Date(),
            topics: [Topic(id: UUID(), title: "Old", summary: "", messageIds: [0])],
            loops: [OpenLoop(id: UUID(), title: "Settle up", detail: "", status: .open, createdDate: Date())]), chatId: chat)
        var largestPrompt = 0
        LLMClient.testResponder = { _, input in
            largestPrompt = max(largestPrompt, input.count)
            return #"{"assignments":[{"start":0,"end":39,"topic":0}],"newLoops":[{"title":"Pay rent","detail":"","message":0,"owner":"me","due":"2099-01-01"}],"resolvedLoops":[0]}"#
        }
        let bg = BackgroundSorter()
        bg.reader = ChatDBReader(path: path)
        var synced: [OpenLoop] = []
        bg.reminderSync = { loops, c, _, _ in if c == chat { synced = loops } }
        await bg.run(settings: settings) { nil }
        XCTAssertLessThanOrEqual(largestPrompt, 8_000 + 12_000, "background prompt wasn't batched (\(largestPrompt) chars)")
        XCTAssertTrue(synced.contains { $0.title == "Pay rent" }, "new follow-up's reminder wasn't synced")
        XCTAssertEqual(synced.first { $0.title == "Settle up" }?.status, .resolved, "settled follow-up's reminder wasn't removed")
    }

    // #1 — changing notification settings resyncs every conversation's reminders.
    func testNotificationSettingChangeResyncsAllConversations() throws {
        let vm = WeftViewModel()
        let before = vm.settings.followedChats
        vm.settings.followedChats = [1_301, 1_302]
        defer { vm.settings.followedChats = before }
        var seen = Set<Int64>()
        Notifier.syncObserver = { chat, _ in seen.insert(chat) }
        defer { Notifier.syncObserver = nil }
        vm.resyncAllReminders()
        XCTAssertEqual(seen, [1_301, 1_302])
    }

    // MARK: - 0.2.4 fixes (Astra's 0.2.3 review)

    // Removing a conversation cancels its reminders; global changes also
    // clean up reminders of removed conversations.
    func testRemovedConversationRemindersAreCancelled() async {
        let vm = WeftViewModel()
        let before = vm.settings.followedChats
        vm.settings.followedChats = [1_401, 1_402]
        defer { vm.settings.followedChats = before }
        var synced: [Int64: [OpenLoop]] = [:]
        Notifier.syncObserver = { chat, loops in synced[chat] = loops }
        defer { Notifier.syncObserver = nil }
        await vm.removeConversation(1_402)
        XCTAssertEqual(synced[1_402]?.count, 0, "removed conversation's reminders weren't cancelled")
        var kept: Set<Int64>?
        Notifier.purgeObserver = { kept = $0 }
        defer { Notifier.purgeObserver = nil }
        vm.resyncAllReminders()
        XCTAssertEqual(kept, [1_401], "orphaned reminders aren't purged on a settings change")
    }

    // Merging away the AI's chosen topic mid-sort: no untitled topic, and the
    // message lands in the topic it was merged into.
    func testMergeDuringSortFollowsTheMerge() async throws {
        LLMClient.testResponder = { _, _ in
            try await Task.sleep(nanoseconds: 300_000_000)
            return #"{"assignments":[{"start":0,"end":0,"topic":0}],"newLoops":[],"resolvedLoops":[]}"#
        }
        let vm = WeftViewModel()
        vm.chats = [ChatInfo(id: 1_500, participants: "x", messageCount: 3, lastDate: nil, lastSnippet: nil)]
        vm.settings.selectedChatRowID = 1_500
        vm.settings.grantConsent(1_500)
        let a = Topic(id: UUID(), title: "A", summary: "", messageIds: [1])
        let b = Topic(id: UUID(), title: "B", summary: "", messageIds: [2])
        vm.messages = [msg(1), msg(2), msg(3)]
        vm.topics = [a, b]                                   // AI will pick topic 0 = A
        vm.pendingMessageIDs = [3]
        vm.retryFiling()
        try await Task.sleep(nanoseconds: 100_000_000)
        vm.editTopics("Merge Topics", undoManager: nil) { TopicEditor.merge($0, a.id, into: b.id) }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(vm.topics.contains { $0.title.trimmingCharacters(in: .whitespaces).isEmpty }, "an untitled topic was created")
        XCTAssertEqual(vm.topics.first { $0.id == b.id }?.messageIds, [1, 2, 3])
    }

    // MARK: - 0.2.5 fixes (Astra's 0.2.4 review)

    // Opening a conversation that was never sorted actually starts its
    // first sort (here: asks for consent) — the message watch used to cancel it.
    func testOpeningConversationStartsItsFirstSort() async throws {
        let chat: Int64 = 1_600
        let path = try fixtureDB([(1, chat, "hi", nil, false), (2, chat, "hello", nil, true)])
        let vm = WeftViewModel()
        vm.reader = ChatDBReader(path: path)
        vm.background.reader = vm.reader
        let before = (vm.settings.followedChats, vm.settings.selectedChatRowID)
        defer { vm.settings.followedChats = before.0; vm.settings.selectedChatRowID = before.1 }
        await vm.selectChat(ChatInfo(id: chat, participants: "x", messageCount: 2, lastDate: nil, lastSnippet: nil))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(vm.messages.map(\.id), [1, 2])
        XCTAssertEqual(vm.firstSortRequest?.id, chat, "the first sort was cancelled before it started")
    }

    private func backgroundFixture(chat: Int64) throws -> (BackgroundSorter, AppSettings, () -> Void) {
        let path = try fixtureDB((1...4).map { (Int64($0), chat, "message \($0)", nil, false) })
        let settings = AppSettings.shared
        settings.provider = .ollama
        settings.setModel("test-model", for: .ollama)
        settings.grantConsent(chat)
        let before = settings.followedChats
        settings.followedChats = [chat]
        try SegmentationCache.save(CachedAnalysis(messageCount: 0, newestRowId: 0, generatedAt: Date(),
            topics: [Topic(id: UUID(), title: "Old", summary: "", messageIds: [0])], loops: []), chatId: chat)
        let bg = BackgroundSorter()
        bg.reader = ChatDBReader(path: path)
        bg.debounce = 0.05
        return (bg, settings, { settings.followedChats = before; settings.provider = .claude })
    }

    // A slow AI (e.g. a local model) isn't interrupted by new activity: the
    // pass finishes and the conversation's checkpoint moves forward.
    func testSlowBackgroundSortSurvivesNewActivity() async throws {
        let chat: Int64 = 1_700
        let (bg, settings, restore) = try backgroundFixture(chat: chat)
        defer { restore() }
        var calls = 0
        LLMClient.testResponder = { _, _ in
            calls += 1
            try await Task.sleep(nanoseconds: 400_000_000)
            return #"{"assignments":[{"start":0,"end":3,"topic":0}],"newLoops":[],"resolvedLoops":[]}"#
        }
        bg.reminderSync = { _, _, _, _ in }
        bg.schedule(settings: settings) { nil }
        try await Task.sleep(nanoseconds: 150_000_000)        // the AI is now working
        for _ in 0..<4 {                                       // polls keep coming
            bg.schedule(settings: settings) { nil }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(SegmentationCache.load(chatId: chat)?.newestRowId, 4, "the slow pass was cancelled")
        XCTAssertEqual(calls, 1, "the queued re-check should find nothing left to send")
    }

    // Removing a conversation while its background sort is running: nothing
    // is saved and its reminders don't come back.
    func testRemovalDuringBackgroundSortSavesNothing() async throws {
        let chat: Int64 = 1_800
        let (bg, settings, restore) = try backgroundFixture(chat: chat)
        defer { restore() }
        LLMClient.testResponder = { _, _ in
            try await Task.sleep(nanoseconds: 300_000_000)
            return #"{"assignments":[{"start":0,"end":3,"topic":0}],"newLoops":[{"title":"Pay rent","detail":"","message":0}],"resolvedLoops":[]}"#
        }
        var synced = false
        bg.reminderSync = { _, _, _, _ in synced = true }
        let run = Task { await bg.run(settings: settings) { nil } }
        try await Task.sleep(nanoseconds: 100_000_000)
        settings.followedChats = []                            // removed mid-sort
        await run.value
        XCTAssertFalse(synced, "reminders came back for a removed conversation")
        XCTAssertEqual(SegmentationCache.load(chatId: chat)?.newestRowId, 0, "a removed conversation was saved")
    }

    // Your reply sent inside a topic goes straight into it AND is checked
    // for follow-ups ("I'll send the contract tomorrow").
    func testReplyInTopicIsCheckedForFollowUps() async throws {
        let chat: Int64 = 1_900
        let promise = "I'll send the contract tomorrow"
        let path = try fixtureDB([(1, chat, "Can you send the contract?", nil, false), (2, chat, promise, nil, true)])
        var sentToAI = ""
        LLMClient.testResponder = { _, input in
            sentToAI = input
            return #"{"assignments":[{"start":0,"end":0,"topic":1}],"newLoops":[{"title":"Send the contract","detail":"","message":0,"owner":"me"}],"resolvedLoops":[]}"#
        }
        let vm = WeftViewModel()
        vm.reader = ChatDBReader(path: path)
        vm.background.reader = vm.reader
        vm.chats = [ChatInfo(id: chat, participants: "x", messageCount: 2, lastDate: nil, lastSnippet: nil)]
        let before = vm.settings.selectedChatRowID
        defer { vm.settings.selectedChatRowID = before }
        vm.settings.selectedChatRowID = chat
        vm.settings.grantConsent(chat)
        let a = Topic(id: UUID(), title: "Contract", summary: "", messageIds: [1])
        let b = Topic(id: UUID(), title: "Other", summary: "", messageIds: [0])
        vm.messages = [msg(1)]                              // seen through 1
        vm.topics = [a, b]
        vm.noteReplySent(inTopic: a.id, text: promise)
        await vm.pollOnce()
        XCTAssertEqual(vm.topics.first { $0.id == a.id }?.messageIds, [1, 2], "reply wasn't filed in its topic")
        try await Task.sleep(nanoseconds: 3_600_000_000)
        XCTAssertTrue(sentToAI.contains(promise), "the reply was never checked")
        XCTAssertTrue(vm.loops.contains { $0.title == "Send the contract" && $0.owner == .me })
        XCTAssertEqual(vm.topics.first { $0.id == a.id }?.messageIds, [1, 2], "the check moved the reply")
        XCTAssertTrue(vm.followUpQueue.isEmpty)
    }

    // Search notices when a message's stored text changes (edited message).
    func testSearchSeesEditedRichText() async throws {
        let old = try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(string: "Dinner at six"), requiringSecureCoding: false)
        let path = try fixtureDB([(1, 9, nil, old, false)])
        let reader = ChatDBReader(path: path)
        let first = try await reader.search("six", inChats: [9])
        XCTAssertEqual(first.map(\.message.id), [1])
        let new = try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(string: "Dinner at seven"), requiringSecureCoding: false)
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE message SET attributedBody = ? WHERE ROWID = 1", -1, &stmt, nil)
        _ = new.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(new.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        sqlite3_step(stmt); sqlite3_finalize(stmt); sqlite3_close(db)
        let edited = try await reader.search("seven", inChats: [9])
        XCTAssertEqual(edited.map(\.message.id), [1], "search kept the old text")
        let stale = try await reader.search("six", inChats: [9])
        XCTAssertTrue(stale.isEmpty)
    }

    // MARK: - 0.2.6 fixes (Astra's 0.2.5 review)

    // Switching away before a topic reply's follow-up check runs: the check
    // still happens when you come back.
    func testUncheckedReplySurvivesSwitchingConversations() async throws {
        let chat: Int64 = 2_000, other: Int64 = 2_001
        let promise = "I'll book the table"
        let path = try fixtureDB([(1, chat, "Can you book dinner?", nil, false), (2, chat, promise, nil, true),
                                  (3, other, "unrelated", nil, false)])
        var sentToAI = ""
        LLMClient.testResponder = { _, input in
            sentToAI += input
            return #"{"assignments":[],"newLoops":[{"title":"Book the table","detail":"","message":0,"owner":"me"}],"resolvedLoops":[]}"#
        }
        let vm = WeftViewModel()
        vm.reader = ChatDBReader(path: path)
        vm.background.reader = vm.reader
        let info = ChatInfo(id: chat, participants: "x", messageCount: 2, lastDate: nil, lastSnippet: nil)
        let otherInfo = ChatInfo(id: other, participants: "y", messageCount: 1, lastDate: nil, lastSnippet: nil)
        vm.chats = [info, otherInfo]
        let before = (vm.settings.followedChats, vm.settings.selectedChatRowID)
        defer { vm.settings.followedChats = before.0; vm.settings.selectedChatRowID = before.1 }
        vm.settings.selectedChatRowID = chat
        vm.settings.grantConsent(chat)
        let a = Topic(id: UUID(), title: "Dinner", summary: "", messageIds: [1])
        vm.messages = [msg(1)]
        vm.topics = [a]
        vm.noteReplySent(inTopic: a.id, text: promise)
        await vm.pollOnce()                                  // reply filed, check queued
        XCTAssertEqual(vm.followUpQueue, [2])
        await vm.selectChat(otherInfo)                       // switch before the check runs
        await vm.selectChat(info)                            // and come back
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(sentToAI.contains(promise), "the reply's follow-up check was lost")
        XCTAssertTrue(vm.loops.contains { $0.title == "Book the table" })
        XCTAssertTrue(vm.followUpQueue.isEmpty)
    }

    // Many replies waiting only for a follow-up check: every batch is
    // checked, not just the first.
    func testAllQueuedRepliesGetChecked() async throws {
        let settings = AppSettings.shared
        settings.provider = .ollama
        settings.setModel("test-model", for: .ollama)
        defer { settings.provider = .claude }
        let chat: Int64 = 2_100
        let long = String(repeating: "word ", count: 400)    // ~2,000 characters each
        var checked = Set<String>()
        LLMClient.testResponder = { _, input in
            for n in 1...8 where input.contains("reply \(n) ") { checked.insert("\(n)") }
            return #"{"assignments":[],"newLoops":[],"resolvedLoops":[]}"#
        }
        let vm = WeftViewModel()
        vm.chats = [ChatInfo(id: chat, participants: "x", messageCount: 9, lastDate: nil, lastSnippet: nil)]
        vm.settings.selectedChatRowID = chat
        vm.settings.grantConsent(chat)
        vm.messages = [msg(1)] + (2...9).map { msg(Int64($0), "reply \($0 - 1) " + long, me: true) }
        vm.topics = [Topic(id: UUID(), title: "A", summary: "", messageIds: Array(1...9))]
        vm.followUpQueue = Set(2...9)
        vm.retryFiling()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(checked.count, 8, "only \(checked.count) of 8 replies were checked")
        XCTAssertTrue(vm.followUpQueue.isEmpty)
    }

    // MARK: - 0.2.7 fixes (Astra's 0.2.6 review)

    private func queuedReplyVM(chat: Int64) -> (WeftViewModel, OpenLoop) {
        let vm = WeftViewModel()
        vm.chats = [ChatInfo(id: chat, participants: "x", messageCount: 2, lastDate: nil, lastSnippet: nil)]
        vm.settings.selectedChatRowID = chat
        vm.settings.grantConsent(chat)
        let loop = OpenLoop(id: UUID(), title: "Old one", detail: "", status: .open, createdDate: Date())
        vm.messages = [msg(1), msg(2, "I'll call them", me: true)]
        vm.topics = [Topic(id: UUID(), title: "A", summary: "", messageIds: [1, 2])]
        vm.loops = [loop]
        vm.followUpQueue = [2]
        return (vm, loop)
    }

    // Editing a follow-up keeps the saved list of replies still to check.
    func testEditingFollowUpKeepsSavedReplyQueue() {
        let (vm, loop) = queuedReplyVM(chat: 2_200)
        vm.setLoopStatus(loop, .resolved)
        XCTAssertEqual(SegmentationCache.load(chatId: 2_200)?.followUpQueue, [2], "editing a follow-up erased the queue")
    }

    // Resuming a paused conversation checks replies that were waiting.
    func testResumeChecksWaitingReplies() async throws {
        var calls = 0
        LLMClient.testResponder = { _, _ in calls += 1; return #"{"assignments":[],"newLoops":[],"resolvedLoops":[]}"# }
        let (vm, _) = queuedReplyVM(chat: 2_300)
        vm.setPaused(2_300, true)
        defer { vm.settings.pausedChats.remove(2_300) }
        vm.setPaused(2_300, false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(calls, 1, "resuming didn't check the waiting reply")
        XCTAssertTrue(vm.followUpQueue.isEmpty)
    }

    // MARK: - 0.2.8 fixes (Astra's 0.2.7 review)

    // A background sort that finishes after you edited the conversation
    // (renamed a topic, completed a follow-up) doesn't undo the edit.
    func testLateBackgroundSortKeepsYourEdits() async throws {
        let chat: Int64 = 2_400
        let (bg, settings, restore) = try backgroundFixture(chat: chat)
        defer { restore() }
        LLMClient.testResponder = { _, _ in
            try await Task.sleep(nanoseconds: 300_000_000)
            return #"{"assignments":[{"start":0,"end":3,"topic":0}],"newLoops":[],"resolvedLoops":[]}"#
        }
        var synced = false
        bg.reminderSync = { _, _, _, _ in synced = true }
        let run = Task { await bg.run(settings: settings) { nil } }
        try await Task.sleep(nanoseconds: 100_000_000)
        // You open it, rename the topic, and switch away again.
        var edited = try XCTUnwrap(SegmentationCache.load(chatId: chat))
        edited.topics[0].title = "Renamed"
        try SegmentationCache.save(edited, chatId: chat)
        await run.value
        XCTAssertEqual(SegmentationCache.load(chatId: chat)?.topics.first?.title, "Renamed", "the background result undid your rename")
        XCTAssertFalse(synced)
        // The next pass picks the work up from your edited version.
        LLMClient.testResponder = { _, _ in #"{"assignments":[{"start":0,"end":3,"topic":0}],"newLoops":[],"resolvedLoops":[]}"# }
        await bg.run(settings: settings) { nil }
        XCTAssertEqual(SegmentationCache.load(chatId: chat)?.newestRowId, 4)
        XCTAssertEqual(SegmentationCache.load(chatId: chat)?.topics.first?.title, "Renamed")
    }

    // Your topic reply that arrives during a full sort ends up in a topic
    // afterwards (not left only in All Messages).
    func testReplyDuringFullSortKeepsATopic() async throws {
        let chat: Int64 = 2_500
        let promise = "I'll bring the wine"
        let path = try fixtureDB([(1, chat, "Dinner Friday?", nil, false), (2, chat, "Sounds good", nil, false), (3, chat, promise, nil, true)])
        LLMClient.testResponder = { system, _ in
            if system.contains("organizing a chat transcript") {
                try await Task.sleep(nanoseconds: 300_000_000)
                return #"[{"title":"Dinner","summary":"s","ranges":[[0,1]]}]"#
            }
            if system.contains("reviewing a chat transcript") { return "[]" }
            return #"{"assignments":[{"start":0,"end":0,"topic":0}],"newLoops":[],"resolvedLoops":[]}"#
        }
        let vm = WeftViewModel()
        vm.reader = ChatDBReader(path: path)
        vm.background.reader = vm.reader
        vm.chats = [ChatInfo(id: chat, participants: "x", messageCount: 3, lastDate: nil, lastSnippet: nil)]
        let before = (vm.settings.selectedChatRowID, vm.settings.sortOlderHistory)
        defer { vm.settings.selectedChatRowID = before.0; vm.settings.sortOlderHistory = before.1 }
        vm.settings.selectedChatRowID = chat
        vm.settings.sortOlderHistory = false                 // history sorting would mask the loss
        vm.settings.grantConsent(chat)
        let a = Topic(id: UUID(), title: "Old", summary: "", messageIds: [1, 2])
        vm.messages = [msg(1), msg(2)]
        vm.topics = [a]
        vm.noteReplySent(inTopic: a.id, text: promise)
        let sort = Task { await vm.analyze() }
        try await Task.sleep(nanoseconds: 100_000_000)
        await vm.pollOnce()                                  // your reply lands mid-sort
        await sort.value
        try await Task.sleep(nanoseconds: 3_600_000_000)
        XCTAssertTrue(vm.topics.contains { $0.messageIds.contains(3) }, "the reply lost its topic")
        XCTAssertTrue(vm.pendingMessageIDs.isEmpty)
        XCTAssertTrue(vm.followUpQueue.isEmpty)
    }

    // MARK: - 0.2.9 (your own casual promises)

    // "I'll let you know when it's ready" becomes a follow-up you owe, even
    // though the other person answered with their own promise.
    func testYourCasualPromiseBecomesAFollowUp() throws {
        let raw = #"{"assignments":[{"start":0,"end":1,"topic":0}],"newLoops":[{"title":"Review newest version","detail":"","message":1,"owner":"them"}],"yourPromises":[{"message":0,"promise":"Tell them when it's ready"}],"resolvedLoops":[]}"#
        let r = try TopicFiler.parse(raw, newMessages: [msg(10, "i'll let you know when it's ready", me: true), msg(11, "Sounds good, I'll review it")],
                                     topics: [Topic(id: UUID(), title: "A", summary: "", messageIds: [1])], openLoops: [])
        XCTAssertEqual(r.newLoops.filter { $0.owner == .me }.map(\.sourceMessageId), [10])
        XCTAssertEqual(r.newLoops.filter { $0.owner == .them }.count, 1)
        // Not from You, out of range, null, or a repeat: ignored.
        let noise = #"{"assignments":[],"newLoops":[{"title":"Tell them","detail":"","message":0,"owner":"me"}],"yourPromises":[{"message":0,"promise":"Tell them"},{"message":1,"promise":"x"},{"message":7,"promise":"y"},{"message":0,"promise":null}],"resolvedLoops":[]}"#
        let n = try TopicFiler.parse(noise, newMessages: [msg(10, "i'll tell them", me: true), msg(11, "ok")], topics: [], openLoops: [])
        XCTAssertEqual(n.newLoops.count, 1)
    }

    // MARK: - 0.3.0 link previews

    // Web addresses in message text are clickable.
    func testLinksInTextAreClickable() {
        let a = LinkText.attributed("see https://example.com/page and example.org")
        let links = a.runs.compactMap(\.link)
        XCTAssertEqual(links.first?.absoluteString, "https://example.com/page")
        XCTAssertEqual(links.count, 2)
        XCTAssertTrue(LinkText.attributed("no links here").runs.allSatisfy { $0.link == nil })
        XCTAssertTrue(LinkText.isJustTheLink(" https://www.example.com/page/ ", URL(string: "https://example.com/page")!))
        XCTAssertFalse(LinkText.isJustTheLink("look at this https://example.com", URL(string: "https://example.com")!))
    }

    // Messages' saved link preview is read without creating anything else
    // from the archive; a preview with an unexpected type is just skipped.
    // The card opens the address that was sent, not the site's own idea of it.
    func testLinkPreviewIsReadFromMessagesArchive() throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("RichLink", for: FakeRichLink.self)
        archiver.setClassName("LPLinkMetadata", for: FakeMetadata.self)
        archiver.setClassName("RichLinkImageAttachmentSubstitute", for: FakeImage.self)
        archiver.encode(FakeRichLink(), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let parsed = LinkPreviewParser.parse(archiver.encodedData)
        XCTAssertEqual(parsed, .init(url: URL(string: "https://example.com/a")!, title: "A page", site: "Example", imageIndex: 1))
        XCTAssertNil(LinkPreviewParser.parse(Data("not an archive".utf8)))
        let other = try NSKeyedArchiver.archivedData(withRootObject: NSDate(), requiringSecureCoding: false)
        XCTAssertNil(LinkPreviewParser.parse(other))
    }

    // MARK: - 0.3.2 (conversations mixed up when switching quickly)

    // Opening B while A is still loading: A's slow load must not take over B
    // (it used to, and A's topics were then saved into B's file).
    func testSlowLoadDoesNotLandInTheNextConversation() async throws {
        let a: Int64 = 2_600, b: Int64 = 2_601
        let path = try fixtureDB([(1, a, "from A", nil, false), (2, a, "more A", nil, true), (3, b, "from B", nil, false)])
        try SegmentationCache.save(CachedAnalysis(messageCount: 2, newestRowId: 2, generatedAt: Date(),
            topics: [Topic(id: UUID(), title: "A topic", summary: "", messageIds: [1, 2])], loops: []), chatId: a)
        try SegmentationCache.save(CachedAnalysis(messageCount: 1, newestRowId: 3, generatedAt: Date(),
            topics: [Topic(id: UUID(), title: "B topic", summary: "", messageIds: [3])], loops: []), chatId: b)
        let vm = WeftViewModel()
        let before = (vm.settings.followedChats, vm.settings.selectedChatRowID)
        defer { vm.settings.followedChats = before.0; vm.settings.selectedChatRowID = before.1 }
        vm.background.reader = ChatDBReader(path: path)
        vm.reader = ChatDBReader(path: path, testDelay: 0.4)          // A loads slowly
        let first = Task { await vm.selectChat(ChatInfo(id: a, participants: "x", messageCount: 2, lastDate: nil, lastSnippet: nil)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        vm.reader = ChatDBReader(path: path)                            // B loads at once
        await vm.selectChat(ChatInfo(id: b, participants: "y", messageCount: 1, lastDate: nil, lastSnippet: nil))
        await first.value
        XCTAssertEqual(vm.settings.selectedChatRowID, b)
        XCTAssertEqual(vm.messages.map(\.id), [3], "A's messages took over B")
        XCTAssertEqual(vm.topics.map(\.title), ["B topic"])
        XCTAssertEqual(SegmentationCache.load(chatId: b)?.topics.map(\.title), ["B topic"], "A's topics were saved into B")
    }

    // A file that already has another conversation's topics mixed in is
    // cleaned when the conversation opens.
    func testMixedUpTopicsAreCleanedOnOpen() async throws {
        let a: Int64 = 2_700, b: Int64 = 2_701
        let path = try fixtureDB([(1, a, "from A", nil, false), (2, b, "from B", nil, false), (3, b, "more B", nil, true)])
        try SegmentationCache.save(CachedAnalysis(messageCount: 2, newestRowId: 3, generatedAt: Date(),
            topics: [Topic(id: UUID(), title: "B topic", summary: "", messageIds: [2]),
                     Topic(id: UUID(), title: "A topic", summary: "", messageIds: [1]),
                     Topic(id: UUID(), title: "Mixed", summary: "", messageIds: [1, 3])],
            loops: [OpenLoop(id: UUID(), title: "From A", detail: "", status: .open, createdDate: Date(), sourceMessageId: 1)]), chatId: b)
        let vm = WeftViewModel()
        let before = (vm.settings.followedChats, vm.settings.selectedChatRowID)
        defer { vm.settings.followedChats = before.0; vm.settings.selectedChatRowID = before.1 }
        vm.reader = ChatDBReader(path: path)
        vm.background.reader = vm.reader
        await vm.selectChat(ChatInfo(id: b, participants: "y", messageCount: 2, lastDate: nil, lastSnippet: nil))
        // The mixed topic is taken apart (its title came from A); B's own
        // message in it waits to be sorted again.
        XCTAssertFalse(vm.topics.contains { $0.title == "Mixed" || $0.title == "A topic" })
        XCTAssertTrue(vm.pendingMessageIDs.contains(3), "B's message from the mixed topic wasn't re-sorted")
        XCTAssertTrue(vm.loops.isEmpty)
        XCTAssertEqual(SegmentationCache.load(chatId: b)?.topics.map(\.title), ["B topic"], "the cleaned version wasn't saved")
    }

    // Right-click → Remove Topic: the topic goes and its messages are sorted
    // again into the right topics.
    func testRemoveTopicResortsItsMessages() async throws {
        LLMClient.testResponder = { _, _ in #"{"assignments":[{"start":0,"end":1,"topic":0}],"newLoops":[],"resolvedLoops":[]}"# }
        let vm = WeftViewModel()
        vm.chats = [ChatInfo(id: 2_900, participants: "x", messageCount: 3, lastDate: nil, lastSnippet: nil)]
        let before = vm.settings.selectedChatRowID
        defer { vm.settings.selectedChatRowID = before }
        vm.settings.selectedChatRowID = 2_900
        vm.settings.grantConsent(2_900)
        let keep = Topic(id: UUID(), title: "Right", summary: "", messageIds: [1])
        let wrong = Topic(id: UUID(), title: "Wrong", summary: "", messageIds: [2, 3])
        vm.messages = [msg(1), msg(2), msg(3)]
        vm.topics = [keep, wrong]
        vm.removeTopic(wrong.id)
        XCTAssertFalse(vm.topics.contains { $0.id == wrong.id })
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(vm.topics.map(\.title), ["Right"])
        XCTAssertEqual(vm.topics.first?.messageIds, [1, 2, 3], "the messages weren't sorted again")
        XCTAssertTrue(vm.pendingMessageIDs.isEmpty)
    }

    // MARK: - 0.3.6 hand-made topics get a summary

    func testHandMadeTopicGetsASummary() async throws {
        var asked = ""
        LLMClient.testResponder = { system, input in
            asked = input
            return system.contains("You summarize one topic") ? "You decided on a handwashable heated mug." : "[]"
        }
        let vm = WeftViewModel()
        vm.chats = [ChatInfo(id: 3_000, participants: "x", messageCount: 2, lastDate: nil, lastSnippet: nil)]
        let before = vm.settings.selectedChatRowID
        defer { vm.settings.selectedChatRowID = before }
        vm.settings.selectedChatRowID = 3_000
        vm.settings.grantConsent(3_000)
        vm.messages = [msg(1, "best handwashable heated mug?", me: true), msg(2, "Try the Ember")]
        vm.topics = [Topic(id: UUID(), title: "Mugs", summary: "Old summary", messageIds: [1, 2])]
        vm.editTopics("Move to New Topic", undoManager: nil) { TopicEditor.moveToNew($0, messages: [1, 2], title: "Heated mug").topics }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(vm.topics.first?.title, "Heated mug", "your title must be kept")
        XCTAssertEqual(vm.topics.first?.summary, "You decided on a handwashable heated mug.")
        XCTAssertTrue(asked.contains("best handwashable heated mug?"))
        XCTAssertEqual(SegmentationCache.load(chatId: 3_000)?.topics.first?.summary, "You decided on a handwashable heated mug.")
    }

    // MARK: - 0.3.7 Haiku 5.5

    // Haiku 5.5 sometimes puts null entries in its lists; the rest of the
    // reply must still be used.
    func testNullEntriesInRepliesAreSkipped() throws {
        let raw = #"{"assignments":[{"start":0,"end":1,"topic":0}],"newLoops":[null,{"title":"Call contractor","detail":"","message":0,"owner":"me"}],"yourPromises":[{"message":0,"promise":"Call them"},null],"resolvedLoops":[]}"#
        let r = try TopicFiler.parse(raw, newMessages: [msg(10, "I'll call them", me: true), msg(11, "ok")],
                                     topics: [Topic(id: UUID(), title: "A", summary: "", messageIds: [1])], openLoops: [])
        XCTAssertEqual(r.assignments.count, 1)
        XCTAssertEqual(r.newLoops.count, 1, "the promise duplicates the listed follow-up, so one in total")
    }

    // Haiku 5.5 has a ~100k-token limit: full sorts send less to it.
    func testHaikuGetsASmallerTranscript() {
        var c = LLMClient(provider: .claude, model: "claude-haiku-5-5")
        XCTAssertEqual(c.transcriptCharLimit, 240_000)
        c.model = "claude-sonnet-5-5"
        XCTAssertEqual(c.transcriptCharLimit, 400_000)
    }

    // MARK: - 0.3.3 removing a conversation forgets it

    func testRemovingConversationForgetsItsTopics() async throws {
        let chat: Int64 = 2_800
        let vm = WeftViewModel()
        let before = vm.settings.followedChats
        defer { vm.settings.followedChats = before }
        vm.settings.followedChats = [chat, 2_801]
        vm.settings.grantConsent(chat)
        try SegmentationCache.save(CachedAnalysis(messageCount: 1, newestRowId: 1, generatedAt: Date(),
            topics: [Topic(id: UUID(), title: "T", summary: "", messageIds: [1])], loops: []), chatId: chat)
        await vm.removeConversation(chat)
        XCTAssertNil(SegmentationCache.load(chatId: chat), "its topics were kept")
        XCTAssertFalse(vm.settings.hasConsent(chat), "adding it back should ask again, like a new conversation")
    }
}

@objc(WeftFakeImage) private final class FakeImage: NSObject, NSCoding {
    override init() {}
    required init?(coder: NSCoder) {}
    func encode(with coder: NSCoder) { coder.encode(1, forKey: "richLinkImageAttachmentSubstituteIndex") }
}
@objc(WeftFakeMetadata) private final class FakeMetadata: NSObject, NSCoding {
    override init() {}
    required init?(coder: NSCoder) {}
    func encode(with coder: NSCoder) {
        coder.encode(NSURL(string: "https://example.com/"), forKey: "URL")        // where the site said it lives
        coder.encode(NSURL(string: "https://example.com/a"), forKey: "originalURL") // what was sent
        coder.encode("A page" as NSString, forKey: "title")
        coder.encode("Example" as NSString, forKey: "siteName")
        coder.encode(FakeImage(), forKey: "image")
        coder.encode(NSDate(), forKey: "somethingElse")
    }
}
@objc(WeftFakeRichLink) private final class FakeRichLink: NSObject, NSCoding {
    override init() {}
    required init?(coder: NSCoder) {}
    func encode(with coder: NSCoder) { coder.encode(FakeMetadata(), forKey: "richLinkMetadata") }
}
