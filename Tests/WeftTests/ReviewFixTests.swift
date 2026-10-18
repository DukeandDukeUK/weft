import XCTest
import SQLite3
@testable import Weft

/// Regression tests for the 0.4.3 review fixes. Nothing here touches real
/// messages: the database is a fixture and the AI is a scripted reply.
@MainActor
final class ReviewFixTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("weft-review-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        SegmentationCache.directoryOverride = scratch
        TokenLog.fileOverride = scratch.appendingPathComponent("token-log.json")
        AppSettings.shared.provider = .claude
    }

    override func tearDown() async throws {
        LLMClient.testResponder = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - attributedBody (typedstream)

    /// The byte layout Messages writes: an NSArchiver typedstream of an
    /// NSMutableAttributedString. Only the parts the parser reads are exact;
    /// the attribute run after the text is representative.
    private func typedStream(_ text: String) -> Data {
        var bytes: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x19]
        bytes += Array("NSMutableAttributedString".utf8) + [0x00, 0x84, 0x84, 0x12]
        bytes += Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84, 0x08]
        bytes += Array("NSObject".utf8) + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x0F]
        bytes += Array("NSMutableString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
        let utf8 = Array(text.utf8)
        if utf8.count < 0x80 {
            bytes.append(UInt8(utf8.count))
        } else {
            bytes += [0x81, UInt8(utf8.count & 0xFF), UInt8(utf8.count >> 8)]
        }
        bytes += utf8
        bytes += [0x86, 0x84, 0x02, 0x69, 0x49, 0x01, UInt8(min(utf8.count, 0x7F)), 0x92, 0x84, 0x84, 0x84, 0x0C]
        bytes += Array("NSDictionary".utf8) + [0x00, 0x94, 0x84, 0x01, 0x69, 0x01, 0x92, 0x84, 0x96, 0x96, 0x1D]
        bytes += Array("__kIMMessagePartAttributeName".utf8) + [0x86, 0x92, 0x84, 0x84, 0x84, 0x08]
        bytes += Array("NSNumber".utf8) + [0x00, 0x84, 0x84, 0x07]
        bytes += Array("NSValue".utf8) + [0x00, 0x94, 0x84, 0x01, 0x2A, 0x84, 0x99, 0x99, 0x00, 0x86, 0x86, 0x86]
        return Data(bytes)
    }

    func testShortTypedStreamBodyIsTheMessageNotTheAttributeName() {
        for text in ["ok", "Hello", "See you at 7 tonight", "👍🏽 sounds good"] {
            XCTAssertEqual(AttributedBodyParser.string(from: typedStream(text)), text)
        }
    }

    func testLongTypedStreamBodyUsesTwoByteLength() {
        let long = String(repeating: "Sounds good, I will send it over tomorrow morning. ", count: 8)
        XCTAssertEqual(AttributedBodyParser.string(from: typedStream(long)), long.trimmingCharacters(in: .whitespaces))
    }

    func testKeyedArchiveBodyStillDecodes() throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(string: "Book the flight"), requiringSecureCoding: false)
        XCTAssertEqual(AttributedBodyParser.string(from: data), "Book the flight")
    }

    func testHeuristicSkipsArchiveNames() {
        // No "+" tag: the heuristic runs, and must not pick the attribute name.
        var bytes: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84]
        bytes += Array("NSMutableAttributedString".utf8) + [0x00, 0x84, 0x84]
        bytes += [0x01, 0x05] + Array("Hello".utf8) + [0x86, 0x84, 0x92, 0x96]
        bytes += Array("__kIMMessagePartAttributeName".utf8) + [0x86]
        XCTAssertEqual(AttributedBodyParser.longestPrintableRun(in: Data(bytes)), "Hello")
    }

    // MARK: - Filing skipped messages

    func testNeighbourTopicIsTheOneHoldingTheMessageBefore() {
        let early = Topic(id: UUID(), title: "Early", summary: "", messageIds: [1, 2, 3])
        let recent = Topic(id: UUID(), title: "Recent", summary: "", messageIds: [40, 41])
        // Most recently active first, as the view model keeps them.
        let topics = [recent, early]
        XCTAssertEqual(TopicEditor.neighborTopicIndex(for: 4, in: topics), 1, "message 4 follows message 3, which is in Early")
        XCTAssertEqual(TopicEditor.neighborTopicIndex(for: 42, in: topics), 0)
        XCTAssertEqual(TopicEditor.neighborTopicIndex(for: 0, in: topics), 1, "before everything: the nearest later message")
        XCTAssertNil(TopicEditor.neighborTopicIndex(for: 5, in: []))
    }

    func testMessageTheAISkipsIsFiledAfterAFewTries() async throws {
        var calls = 0
        LLMClient.testResponder = { system, _ in
            if system.contains("file new messages") { calls += 1 }
            return #"{"assignments":[],"newLoops":[],"resolvedLoops":[]}"#   // never places anything
        }
        let vm = WeftViewModel()
        let chat: Int64 = 3_100
        vm.chats = [ChatInfo(id: chat, participants: "x", messageCount: 2, lastDate: nil, lastSnippet: nil)]
        vm.settings.selectedChatRowID = chat
        vm.settings.grantConsent(chat)
        let a = Topic(id: UUID(), title: "A", summary: "", messageIds: [1])
        vm.messages = [ChatMessage(id: 1, text: "hello", isFromMe: false, date: Date(), handleId: "x"),
                       ChatMessage(id: 2, text: "[attachment]", isFromMe: false, date: Date(), handleId: "x")]
        vm.topics = [a]
        vm.pendingMessageIDs = [2]
        for _ in 0..<WeftViewModel.maxFilingAttempts {
            vm.retryFiling()
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTAssertEqual(calls, WeftViewModel.maxFilingAttempts)
        XCTAssertTrue(vm.pendingMessageIDs.isEmpty, "still waiting after \(calls) tries")
        XCTAssertEqual(vm.topics.first { $0.id == a.id }?.messageIds, [1, 2])
        // And it's left alone afterwards.
        vm.retryFiling()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(calls, WeftViewModel.maxFilingAttempts, "a filed message was sent again")
    }

    // MARK: - Conversation colours

    func testAutomaticColourIsStableAndPerPerson() {
        XCTAssertEqual(ConversationColors.automaticIndex(forChat: 42), ConversationColors.automaticIndex(forChat: 42))
        XCTAssertNotEqual(ConversationColors.automaticIndex(forChat: 42), ConversationColors.automaticIndex(forChat: 43))
        XCTAssertEqual(ConversationColors.automaticIndex(forHandle: "+15555550100"), ConversationColors.automaticIndex(forHandle: "+15555550100"))
        let all = Set(ConversationColors.all.indices.map { ConversationColors.palette(index: $0).hueIndex })
        XCTAssertEqual(all.count, ConversationColors.all.count)
        XCTAssertEqual(ConversationColors.palette(index: -1).hueIndex, ConversationColors.all.count - 1)
    }

    func testChosenColourIsKeptAndForgottenWithTheConversation() {
        let settings = AppSettings.shared
        let chat: Int64 = 3_200
        XCTAssertNil(settings.hueIndex(forChat: chat))
        settings.setHueIndex(2, forChat: chat)
        XCTAssertEqual(ConversationColors.index(forChat: chat, settings: settings), 2)
        settings.forgetConversation(chat)
        XCTAssertNil(settings.hueIndex(forChat: chat))
        XCTAssertEqual(ConversationColors.index(forChat: chat, settings: settings), ConversationColors.automaticIndex(forChat: chat))
    }

    // MARK: - Child processes

    func testOutputCollectorReadsUntilExitEvenIfAPipeStaysOpen() throws {
        // A shell that prints, then leaves a grandchild holding stdout open.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "echo hello; echo oops 1>&2; (sleep 5) & exit 0"]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        let collector = OutputCollector()
        collector.attach(stdout: out.fileHandleForReading, stderr: err.fileHandleForReading)
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        try proc.run()
        let started = Date()
        XCTAssertEqual(exited.wait(timeout: .now() + 10), .success)
        collector.waitForEOF(seconds: 1)
        let (stdout, stderr) = collector.finish()
        XCTAssertEqual(String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertEqual(String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "oops")
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "waited for the grandchild instead of the child")
    }

    func testBlockingWorkReturnsValuesAndErrors() async throws {
        struct Boom: Error {}
        let value = try await BlockingWork.run { 6 * 7 }
        XCTAssertEqual(value, 42)
        do {
            _ = try await BlockingWork.run { () -> Int in throw Boom() }
            XCTFail("no error")
        } catch is Boom {
        }
    }
}
