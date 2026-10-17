import XCTest
import SwiftUI
@testable import Weft

/// Draws the message list off screen (no screen capture) to check what a
/// person would actually see.
@MainActor
final class MessageListRenderTests: XCTestCase {
    /// Switching to a long conversation: its messages arrive just after the
    /// view opens. It must show messages, not a blank area (it used to stay
    /// blank until something new was sent).
    func testLongConversationOpensWithMessagesShowing() async throws {
        let vm = WeftViewModel()
        let words = ["mug", "trip", "quote", "contractor", "speaker", "permit", "flight", "dinner"]
        var all: [ChatMessage] = []
        for i in 1...1_500 {
            let count = 5 + (i * 7) % 60
            let text = (0..<count).map { words[($0 + i) % words.count] }.joined(separator: " ")
            let mine = i % 3 == 0
            let date = Date(timeIntervalSince1970: 1_780_000_000 + Double(i) * 600)
            all.append(ChatMessage(id: Int64(i), text: text, isFromMe: mine, date: date, handleId: mine ? "" : "x"))
        }
        vm.sidebarSelection = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: MessageListView(viewModel: vm).background(Color.white))
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 200_000_000)
        vm.messages = all
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var nonWhite = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 8) {
                if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.9 { nonWhite += 1 }
            }
        }
        XCTAssertGreaterThan(nonWhite, 500, "the conversation opened blank")
    }
}
