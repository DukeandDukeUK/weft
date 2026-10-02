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
}
