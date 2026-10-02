import Foundation

// MARK: - BackgroundSorter

/// Keeps the conversations you aren't looking at sorted: when Messages
/// writes new messages, each added conversation's new messages are filed
/// into its saved threads (one small AI call per conversation with news),
/// and conversations with unread messages get a dot.
///
/// The open conversation is handled by WeftViewModel itself; this only
/// touches the others, through their saved analysis files.
@MainActor @Observable
final class BackgroundSorter {
    /// New incoming messages per conversation since you last looked.
    private(set) var unreadCounts: [Int64: Int] = [:]
    /// Conversations with new messages (for the sidebar).
    var unread: Set<Int64> { Set(unreadCounts.filter { $0.value > 0 }.keys) }
    /// Called after each pass (to refresh the Dock badge).
    var onChange: (() -> Void)?
    /// Display names for banners.
    var conversationName: (Int64) -> String = { _ in "Messages" }
    private var running = false
    private var pending: Task<Void, Never>?

    /// Debounced: a burst of writes to Messages becomes one pass.
    /// - Parameter openChat: which conversation is open right now (checked
    ///   again before saving, in case you switch while it's working).
    func schedule(settings: AppSettings, openChat: @escaping @MainActor () -> Int64?) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.run(settings: settings, openChat: openChat)
        }
    }

    func markRead(_ chat: Int64) {
        unreadCounts[chat] = 0
        onChange?()
    }

    private func run(settings: AppSettings, openChat: @MainActor () -> Int64?) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let reader = ChatDBReader.shared
        for chat in settings.followedChats where chat != openChat() {
            // New-message count, and a banner for anything not yet announced.
            let viewed = settings.lastViewedRowID(chat: chat)
            unreadCounts[chat] = (try? await reader.countIncoming(chatRowID: chat, after: viewed)) ?? 0
            if (unreadCounts[chat] ?? 0) > 0,
               let recent = try? await reader.fetchMessages(chatRowID: chat, after: viewed, newest: 20) {
                Notifier.shared.announce(recent.map(WeftViewModel.labeled), chat: chat,
                                         conversationName: conversationName(chat), settings: settings)
            }
            await fileNew(chat: chat, settings: settings, openChat: openChat)
        }
        onChange?()
    }

    private func fileNew(chat: Int64, settings: AppSettings, openChat: @MainActor () -> Int64?) async {
        // Only conversations that have been sorted once (opened in Weft).
        guard var saved = SegmentationCache.load(chatId: chat), !saved.topics.isEmpty,
              var client = settings.makeClient() else { return }
        let reader = ChatDBReader.shared
        guard var fresh = try? await reader.fetchMessages(chatRowID: chat, after: saved.newestRowId),
              !fresh.isEmpty else { return }
        fresh = fresh.map { var m = $0; m.senderName = Self.senderName(m); return m }

        let byActivity = saved.topics.sorted { ($0.messageIds.max() ?? 0) > ($1.messageIds.max() ?? 0) }
        let candidates = Array(byActivity.prefix(60))
        let titleByID = Dictionary(candidates.flatMap { t in t.messageIds.map { ($0, t.title) } }, uniquingKeysWith: { a, _ in a })
        let context = ((try? await reader.fetchContext(chatRowID: chat, upTo: saved.newestRowId, limit: 12)) ?? [])
            .map { m -> (ChatMessage, String) in
                var m = m; m.senderName = Self.senderName(m)
                return (m, titleByID[m.id] ?? "unsorted")
            }
        client.effort = "low"
        guard let result = try? await TopicFiler(client: client).file(
            newMessages: fresh,
            context: context,
            topics: candidates,
            openLoops: saved.loops.filter { $0.status == .open }
        ) else { return } // try again on the next change

        var topics = saved.topics
        var filed = Set<Int64>()
        let already = Set(topics.flatMap(\.messageIds))
        for a in result.assignments {
            let ids = a.messageIds.filter { !already.contains($0) }
            if let i = a.topicIndex, let target = topics.firstIndex(where: { $0.id == candidates[i].id }) {
                topics[target].messageIds.append(contentsOf: ids)
                topics[target].messageIds.sort()
                if let s = a.updatedSummary, !s.isEmpty { topics[target].summary = s }
            } else if !ids.isEmpty {
                topics.append(Topic(id: UUID(), title: a.newTitle, summary: a.newSummary, messageIds: ids))
            }
            filed.formUnion(a.messageIds)
        }
        topics.sort { ($0.messageIds.max() ?? 0) > ($1.messageIds.max() ?? 0) }

        var loops = saved.loops
        for loop in result.newLoops where !loops.contains(where: { $0.title.caseInsensitiveCompare(loop.title) == .orderedSame }) {
            loops.append(loop)
        }
        let resolved = Set(result.resolvedLoopIDs)
        for i in loops.indices where loops[i].status == .open && resolved.contains(loops[i].id) {
            loops[i].status = .resolved
        }

        saved.topics = topics
        saved.loops = loops
        saved.generatedAt = Date()
        // Advance only past what was filed, so skipped messages get retried.
        let freshIDs = fresh.map(\.id)
        if let firstUnfiled = freshIDs.first(where: { !filed.contains($0) }) {
            saved.newestRowId = freshIDs.filter { $0 < firstUnfiled }.max() ?? saved.newestRowId
        } else {
            saved.newestRowId = freshIDs.max() ?? saved.newestRowId
        }
        // Opened while we were working? The open view owns it now.
        guard openChat() != chat else { return }
        try? SegmentationCache.save(saved, chatId: chat)
    }

    static func senderName(_ m: ChatMessage) -> String {
        if m.isFromMe || m.handleId.isEmpty { return "" }
        return ContactNames.shared.name(for: m.handleId) ?? m.handleId
    }
}
