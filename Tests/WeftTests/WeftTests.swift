import XCTest
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

    // First sort waits for consent, and consent is remembered.
    func testFirstSortConsent() {
        let vm = WeftViewModel()
        let chat = ChatInfo(id: 404, participants: "x", messageCount: 1, lastDate: nil, lastSnippet: nil)
        vm.firstSortRequest = chat
        vm.approveFirstSort()
        XCTAssertNil(vm.firstSortRequest)
        XCTAssertTrue(vm.settings.consentedChats.contains(404))
        vm.settings.consentedChats.remove(404)
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
}
