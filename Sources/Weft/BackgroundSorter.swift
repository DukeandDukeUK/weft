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
    /// Conversation being filed right now (for the queue).
    private(set) var working: Int64?
    /// Updates a conversation's reminders (tests replace this).
    var reminderSync: (_ loops: [OpenLoop], _ chat: Int64, _ name: String, _ settings: AppSettings) -> Void = { loops, chat, name, settings in
        Notifier.shared.syncReminders(loops: loops, chat: chat, conversationName: name, settings: settings)
    }
    /// Display names for banners.
    var conversationName: (Int64) -> String = { _ in "Messages" }
    private var running = false
    private var pending: Task<Void, Never>?

    /// Debounced: a burst of writes to Messages becomes one pass.
    private var debounceTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var rerunRequested = false
    /// Pause after Messages writes before a pass (tests shorten it).
    var debounce: Double = 3

    /// Debounced: a burst of writes to Messages becomes one pass. A pass
    /// that's already running is never cancelled (a slow local model would
    /// otherwise be interrupted every poll) — another pass is queued after it.
    /// - Parameter openChat: which conversation is open right now (checked
    ///   again before saving, in case you switch while it's working).
    func schedule(settings: AppSettings, openChat: @escaping @MainActor () -> Int64?) {
        if worker != nil {
            rerunRequested = true
            return
        }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.startWorker(settings: settings, openChat: openChat)
        }
    }

    private func startWorker(settings: AppSettings, openChat: @escaping @MainActor () -> Int64?) {
        guard worker == nil else { rerunRequested = true; return }
        worker = Task { [weak self] in
            await self?.run(settings: settings, openChat: openChat)
            guard let self else { return }
            self.worker = nil
            if self.rerunRequested {
                self.rerunRequested = false
                self.schedule(settings: settings, openChat: openChat)
            }
        }
    }

    func markRead(_ chat: Int64) {
        unreadCounts[chat] = 0
        onChange?()
    }

    /// Which database to read (tests use a fixture).
    var reader: ChatDBReader = .shared

    func run(settings: AppSettings, openChat: @MainActor () -> Int64?) async {
        guard !running else { return }
        running = true
        defer { running = false }
        for chat in settings.followedChats where chat != openChat() {
            // New-message count, and a banner for anything not yet announced.
            let viewed = settings.lastViewedRowID(chat: chat)
            unreadCounts[chat] = (try? await reader.countIncoming(chatRowID: chat, after: viewed)) ?? 0
            if (unreadCounts[chat] ?? 0) > 0,
               let recent = try? await reader.fetchMessages(chatRowID: chat, after: viewed, newest: 20) {
                Notifier.shared.announce(recent.map(WeftViewModel.labeled), chat: chat,
                                         conversationName: conversationName(chat), settings: settings)
            }
            // Paused conversations: still counted for the badge, never sent.
            if !settings.pausedChats.contains(chat) {
                working = chat
                await fileNew(chat: chat, settings: settings, openChat: openChat)
                working = nil
            }
        }
        onChange?()
    }

    private func fileNew(chat: Int64, settings: AppSettings, openChat: @MainActor () -> Int64?) async {
        // Only conversations that have been sorted once (opened in Weft).
        // Only with your OK for this conversation and this destination.
        let revision = SegmentationCache.revision(chatId: chat)
        guard settings.hasConsent(chat),
              var saved = SegmentationCache.load(chatId: chat), !saved.topics.isEmpty,
              var client = settings.makeClient() else { return }
        guard let waiting = try? await reader.fetchMessages(chatRowID: chat, after: saved.newestRowId),
              !waiting.isEmpty else { return }
        // Same size limits as the open conversation; the rest go next pass.
        var fresh = WeftViewModel.batch(waiting, local: settings.provider?.isLocal ?? false)
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
        for loop in result.newLoops where !loops.contains(where: { $0.matches(loop) }) {
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
        // Removed meanwhile? Then nothing is saved and no reminders return.
        // Edited meanwhile (renamed a topic, completed a follow-up…)? Don't
        // overwrite that: drop this result, the next pass starts from the edit.
        guard openChat() != chat, settings.followedChats.contains(chat),
              SegmentationCache.revision(chatId: chat) == revision else { return }
        try? SegmentationCache.save(saved, chatId: chat)
        // New or settled follow-ups: keep their reminders in step.
        reminderSync(saved.loops, chat, conversationName(chat), settings)
    }

    static func senderName(_ m: ChatMessage) -> String {
        if m.isFromMe || m.handleId.isEmpty { return "" }
        return ContactNames.shared.name(for: m.handleId) ?? m.handleId
    }
}
