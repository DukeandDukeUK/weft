import Foundation
import AppKit

// MARK: - WeftViewModel

/// @MainActor UI state. All SQLite access goes through the ChatDBReader actor;
/// all sends go through MessageSender (detached so osascript never blocks UI).
@MainActor @Observable
final class WeftViewModel {
    let settings = AppSettings.shared

    // Data
    var chats: [ChatInfo] = []
    var messages: [ChatMessage] = [] {
        didSet { dateByID = Dictionary(messages.map { ($0.id, $0.date) }, uniquingKeysWith: { a, _ in a }) }
    }
    @ObservationIgnored private var dateByID: [Int64: Date] = [:]

    /// When a thread last had a message (for "2m" / "Yesterday" in the sidebar).
    func lastActivity(of topic: Topic) -> Date? {
        topic.messageIds.max().flatMap { dateByID[$0] }
    }
    var topics: [Topic] = []
    var loops: [OpenLoop] = []

    // UI state
    var sidebarSelection: SidebarSelection? = .all
    var searchText = ""
    var showChatPicker = false
    var showSettings = false
    var isLoading = false
    var isAnalyzing = false
    var isSending = false
    var notice: String?
    var dbMissing = false
    /// First launch before Full Disk Access is granted.
    var needsFullDiskAccess = false
    /// Set when Ollama is the sorter and a better model for this Mac is
    /// recommended but not downloaded yet.
    var betterLocalModel: Recommendations.LocalTier?
    let localPull = OllamaPull()
    var topicsStale = false
    /// Incremented to ask the message list to scroll to bottom (topic change, send).
    var scrollToken = 0
    /// A specific message to jump to (search result tap).
    var jumpToMessageID: Int64?

    /// New messages already shown (in the topic you're viewing, or the most
    /// recently active one) but not yet filed by Claude.
    var pendingMessageIDs: Set<Int64> = []

    private var pollTask: Task<Void, Never>?
    private var watcher: ChatDBWatcher?
    private var isPolling = false
    private var autoSortTask: Task<Void, Never>?
    private var lastSeenRowID: Int64 = 0
    /// Newest reaction row applied (reactions are separate rows in chat.db).
    private var lastReactionRowID: Int64 = 0
    /// Where each pending message is shown until Claude files it.
    private var provisionalTopic: [Int64: UUID] = [:]
    /// The thread you last replied in from this app. Your message and
    /// the replies after it go straight into this thread (no sorting
    /// call) until you reply elsewhere, send from your phone, or 30 minutes pass.
    private var activeThread: (topicID: UUID, sentText: String, at: Date)?

    var selectedTopic: Topic? {
        guard case .topic(let id)? = sidebarSelection else { return nil }
        return topics.first { $0.id == id }
    }

    func openThread(_ id: UUID) {
        sidebarSelection = .topic(id)
        scrollToken += 1
    }

    var selectedChat: ChatInfo? {
        guard let id = settings.selectedChatRowID else { return nil }
        return chats.first { $0.id == id }
    }

    /// Sending is only supported for 1:1 conversations (one handle).
    var canSend: Bool {
        let handle = settings.selectedHandleId
        return !handle.isEmpty && !handle.contains(",")
    }

    var openLoopCount: Int { loops.filter { $0.status == .open }.count }

    var visibleMessages: [ChatMessage] {
        switch sidebarSelection {
        case .topic(let id)?:
            guard let topic = topics.first(where: { $0.id == id }) else { return messages }
            let ids = Set(topic.messageIds)
            return messages.filter { ids.contains($0.id) }
        default:
            // .all, .loop (loop detail replaces the list; see DetailView), nil
            return messages
        }
    }

    var searchResults: [ChatMessage] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return messages.filter { $0.text.localizedCaseInsensitiveContains(q) }.suffix(200).reversed()
    }

    // MARK: - Lifecycle

    static let noAIMessage = "No AI is set up to sort messages yet. Open Settings (gear icon) and pick one."

    func startup() async {
        await RecommendationStore.shared.refresh()
        await settings.autoPickProviderIfNeeded()
        await checkForBetterLocalModel()
        isLoading = true
        defer { isLoading = false }
        notice = nil
        dbMissing = false
        let reader = ChatDBReader.shared
        switch await reader.checkAccess() {
        case .ok:
            needsFullDiskAccess = false
            // Names for the picker and title (asks for Contacts once).
            await ContactNames.shared.load()
        case .noPermission:
            // macOS shows its own "Quit & Reopen" prompt when the switch is
            // turned on, so Weft just waits for that.
            needsFullDiskAccess = true
            return
        case .missing:
            dbMissing = true
            return
        }
        do {
            chats = try await reader.listChats()
        } catch {
            notice = error.localizedDescription
            return
        }
        if let saved = settings.selectedChatRowID,
           let chat = chats.first(where: { $0.id == saved }) {
            await selectChat(chat)
        } else {
            showChatPicker = true
        }
    }

    /// Restart Weft so macOS applies newly granted Full Disk Access.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? proc.run()
        NSApplication.shared.terminate(nil)
    }

    func selectChat(_ chat: ChatInfo) async {
        stopPolling()
        settings.selectedChatRowID = chat.id
        // For 1:1 chats the single participant is who we send to.
        settings.selectedHandleId = chat.participants
        sidebarSelection = .all
        searchText = ""
        topics = []
        loops = []
        topicsStale = false
        isLoading = true
        defer { isLoading = false }
        do {
            messages = try await ChatDBReader.shared.fetchMessages(chatRowID: chat.id)
            lastSeenRowID = messages.last?.id ?? 0
            lastReactionRowID = 0
            await applyNewReactions(chatRowID: chat.id)
            pendingMessageIDs = []
            provisionalTopic = [:]
            // Restore the saved topics, then file anything that arrived while
            // the app was closed. No saved topics yet -> one full sort.
            if let cached = SegmentationCache.load(chatId: chat.id), !cached.topics.isEmpty {
                topics = cached.topics
                loops = cached.loops
                showProvisionally(messages.filter { $0.id > cached.newestRowId })
                if !pendingMessageIDs.isEmpty { scheduleAutoSort(after: 0) }
            } else if !messages.isEmpty {
                scheduleAutoSort(after: 0)
            }
            scrollToken += 1
            startPolling()
        } catch {
            notice = error.localizedDescription
        }
    }

    // MARK: - Polling (5s; no FSEvents — simple and robust)

    /// New messages are picked up the moment Messages writes them (file
    /// watch on its database), with a slow poll as a safety net.
    private func startPolling() {
        stopPolling()
        guard settings.selectedChatRowID != nil else { return }
        watcher = ChatDBWatcher { [weak self] in
            Task { @MainActor in await self?.pollOnce() }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.pollOnce()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        watcher?.stop()
        watcher = nil
        autoSortTask?.cancel()
        autoSortTask = nil
    }

    func pollOnce() async {
        guard let chatId = settings.selectedChatRowID, !isPolling else { return }
        isPolling = true
        defer { isPolling = false }
        do {
            let known = Set(messages.map(\.id))
            let fresh = try await ChatDBReader.shared
                .fetchMessages(chatRowID: chatId, after: lastSeenRowID)
                .filter { !known.contains($0.id) }
            if !fresh.isEmpty {
                messages.append(contentsOf: fresh)
                lastSeenRowID = max(lastSeenRowID, fresh.map(\.id).max() ?? 0)
            }
            // Reactions can arrive on their own, after the message they're on.
            await applyNewReactions(chatRowID: chatId)
            guard !fresh.isEmpty else { return }
            let unfiled = fileIntoActiveThread(fresh)
            if !unfiled.isEmpty {
                showProvisionally(unfiled)
                // Short pause so a burst of replies is filed in one call.
                scheduleAutoSort(after: 3)
            }
        } catch {
            // Polling failures are transient (e.g. DB briefly locked); don't
            // spam the user. The next tick retries.
        }
    }

    // MARK: - Analysis

    /// Full re-sort of the whole conversation. Runs automatically only when a
    /// conversation has no saved topics; otherwise new messages are filed
    /// incrementally by `fileNewMessages()`.
    func analyze() async {
        guard !messages.isEmpty, settings.selectedChatRowID != nil, !isAnalyzing else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }
        let snapshot = messages
        guard let client = settings.makeClient() else {
            notice = Self.noAIMessage
            return
        }
        do {
            async let segmented = TopicSegmenter(client: client).segment(messages: snapshot)
            async let detected = OpenLoopDetector(client: client).detect(messages: snapshot)
            let (newTopics, newLoops) = try await (segmented, detected)
            loops = mergeLoops(newLoops)
            let covered = Set(snapshot.map(\.id))
            topics = newTopics
            // Anything that arrived during the sort is still pending.
            pendingMessageIDs = pendingMessageIDs.subtracting(covered)
            provisionalTopic = provisionalTopic.filter { !covered.contains($0.key) }
            showProvisionally(messages.filter { pendingMessageIDs.contains($0.id) })
            sortTopicsByActivity()
            topicsStale = false
            saveCache(filedThrough: snapshot.map(\.id).max() ?? 0)
        } catch {
            topicsStale = true
            notice = "Sorting failed: \(error.localizedDescription)"
        }
        if !pendingMessageIDs.isEmpty { scheduleAutoSort(after: 3) }
    }

    // MARK: - Better local model

    private static func dismissedKey(_ model: String) -> String { "weft.dismissedModel.\(model)" }

    func checkForBetterLocalModel() async {
        betterLocalModel = nil
        guard settings.provider == .ollama,
              let tier = RecommendationStore.shared.current.recommendedLocalModel(),
              settings.effectiveModel(for: .ollama) != tier.model,
              !UserDefaults.standard.bool(forKey: Self.dismissedKey(tier.model)),
              let installed = await LocalServer.listModels(.ollama),
              !installed.contains(tier.model) else { return }
        betterLocalModel = tier
    }

    func dismissBetterLocalModel() {
        if let model = betterLocalModel?.model {
            UserDefaults.standard.set(true, forKey: Self.dismissedKey(model))
        }
        betterLocalModel = nil
    }

    /// Download the recommended model and switch sorting to it.
    func installBetterLocalModel() async {
        guard let tier = betterLocalModel else { return }
        await localPull.run(model: tier.model)
        if localPull.error == nil {
            settings.setModel(tier.model, for: .ollama)
            betterLocalModel = nil
        }
    }

    // MARK: - Reactions

    /// Apply reaction rows newer than the last one seen: each person has at
    /// most one reaction of a kind per message; a removal row takes it back.
    private func applyNewReactions(chatRowID: Int64) async {
        guard let events = try? await ChatDBReader.shared.fetchReactions(chatRowID: chatRowID, after: lastReactionRowID),
              !events.isEmpty else { return }
        lastReactionRowID = events.map(\.rowID).max() ?? lastReactionRowID
        var indexByGuid: [String: Int] = [:]
        for (i, m) in messages.enumerated() where !m.guid.isEmpty { indexByGuid[m.guid] = i }
        for event in events {
            guard let i = indexByGuid[event.targetGuid] else { continue }
            var reactions = messages[i].reactions
            if event.isRemoval {
                reactions.removeAll { $0.isFromMe == event.isFromMe && $0.emoji == event.emoji }
            } else {
                // Classic tapbacks replace the same person's previous one.
                reactions.removeAll { $0.isFromMe == event.isFromMe }
                reactions.append(Reaction(emoji: event.emoji, isFromMe: event.isFromMe))
            }
            messages[i].reactions = reactions
        }
    }

    // MARK: - Automatic filing

    /// Puts messages that belong to the thread you're replying in straight
    /// into it. Returns the ones that still need Claude to file them.
    private func fileIntoActiveThread(_ fresh: [ChatMessage]) -> [ChatMessage] {
        guard let thread = activeThread,
              Date().timeIntervalSince(thread.at) < 30 * 60,
              let index = topics.firstIndex(where: { $0.id == thread.topicID }) else {
            activeThread = nil
            return fresh
        }
        var unfiled: [ChatMessage] = []
        for (offset, message) in fresh.enumerated() {
            // A message you typed somewhere else (your phone) means the
            // conversation has moved on: let Claude file it and the rest.
            if message.isFromMe && message.text != thread.sentText {
                activeThread = nil
                unfiled.append(contentsOf: fresh[offset...])
                break
            }
            if !topics[index].messageIds.contains(message.id) {
                topics[index].messageIds.append(message.id)
            }
        }
        sortTopicsByActivity()
        let filedThrough = messages.map(\.id).filter { !pendingMessageIDs.contains($0) && !unfiled.map(\.id).contains($0) }.max() ?? 0
        saveCache(filedThrough: filedThrough)
        return unfiled
    }

    /// Show new messages immediately: in the topic you're looking at, or else
    /// the most recently active topic. Claude then files them properly.
    private func showProvisionally(_ fresh: [ChatMessage]) {
        guard !fresh.isEmpty, !topics.isEmpty else {
            pendingMessageIDs.formUnion(fresh.map(\.id))
            return
        }
        let targetID: UUID
        if case .topic(let id)? = sidebarSelection, topics.contains(where: { $0.id == id }) {
            targetID = id
        } else {
            targetID = topics[0].id // list is kept most-recently-active first
        }
        guard let index = topics.firstIndex(where: { $0.id == targetID }) else { return }
        for message in fresh where !topics[index].messageIds.contains(message.id) {
            topics[index].messageIds.append(message.id)
            provisionalTopic[message.id] = targetID
            pendingMessageIDs.insert(message.id)
        }
    }

    private func scheduleAutoSort(after seconds: Double) {
        autoSortTask?.cancel()
        autoSortTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.autoSort()
        }
    }

    private func autoSort() async {
        guard !isAnalyzing else {
            scheduleAutoSort(after: 3)
            return
        }
        if topics.isEmpty {
            await analyze()
        } else {
            await fileNewMessages()
        }
    }

    /// Ask Claude where the pending messages belong, given the existing topics.
    private func fileNewMessages() async {
        let batch = messages.filter { pendingMessageIDs.contains($0.id) }
        guard !batch.isEmpty else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }

        let batchIDs = Set(batch.map(\.id))
        // Topics as they are without the provisional placements.
        var base = topics.map { topic -> Topic in
            var t = topic
            t.messageIds.removeAll { pendingMessageIDs.contains($0) }
            return t
        }.filter { !$0.messageIds.isEmpty }
        let candidates = Array(base.prefix(60))
        let titleByMessage = Dictionary(
            candidates.flatMap { t in t.messageIds.map { ($0, t.title) } },
            uniquingKeysWith: { first, _ in first }
        )
        let firstNew = batch.first!.id
        let context = messages
            .filter { $0.id < firstNew && !pendingMessageIDs.contains($0.id) }
            .suffix(12)
            .map { ($0, titleByMessage[$0.id] ?? "unsorted") }
        let openTitles = loops.filter { $0.status == .open }.map(\.title)

        // Filing is a simple job: low reasoning keeps it to a few seconds.
        guard var client = settings.makeClient() else {
            notice = Self.noAIMessage
            return
        }
        client.effort = "low"
        do {
            let result = try await TopicFiler(client: client).file(
                newMessages: batch,
                context: Array(context),
                topics: candidates,
                openLoopTitles: openTitles
            )
            var filed = Set<Int64>()
            for a in result.assignments {
                if let i = a.topicIndex,
                   let target = base.firstIndex(where: { $0.id == candidates[i].id }) {
                    base[target].messageIds.append(contentsOf: a.messageIds)
                    if let s = a.updatedSummary, !s.isEmpty { base[target].summary = s }
                } else {
                    base.append(Topic(id: UUID(), title: a.newTitle, summary: a.newSummary, messageIds: a.messageIds))
                }
                filed.formUnion(a.messageIds)
            }
            for i in base.indices { base[i].messageIds.sort() }

            // Loops: add new ones, close the ones these messages resolved.
            loops = mergeLoops(result.newLoops)
            let resolved = Set(result.resolvedLoopTitles.map { $0.lowercased() })
            for i in loops.indices where loops[i].status == .open && resolved.contains(loops[i].title.lowercased()) {
                loops[i].status = .resolved
            }

            // Messages Claude skipped, or that arrived during the call, stay
            // where they're shown and get another pass.
            let stillPending = pendingMessageIDs.subtracting(filed)
            topics = base
            pendingMessageIDs = []
            let provisional = provisionalTopic
            provisionalTopic = [:]
            for id in stillPending.sorted() {
                guard let message = messages.first(where: { $0.id == id }) else { continue }
                if let topicID = provisional[id], let index = topics.firstIndex(where: { $0.id == topicID }) {
                    topics[index].messageIds.append(id)
                    provisionalTopic[id] = topicID
                    pendingMessageIDs.insert(id)
                } else {
                    sortTopicsByActivity()
                    showProvisionally([message])
                }
            }
            sortTopicsByActivity()
            topicsStale = false
            let filedThrough = messages.map(\.id).filter { !pendingMessageIDs.contains($0) }.max() ?? 0
            saveCache(filedThrough: filedThrough)
            if !stillPending.subtracting(batchIDs).isEmpty || !filed.isSuperset(of: batchIDs) {
                scheduleAutoSort(after: 3)
            }
        } catch {
            topicsStale = true
            notice = "Couldn't sort new messages: \(error.localizedDescription)"
        }
    }

    /// Most recently active topic first (Mail-style).
    private func sortTopicsByActivity() {
        topics.sort { ($0.messageIds.max() ?? 0) > ($1.messageIds.max() ?? 0) }
    }

    private func saveCache(filedThrough: Int64) {
        guard let chatId = settings.selectedChatRowID else { return }
        // Don't save provisional placements — they get re-filed on next launch.
        let saved = topics.map { topic -> Topic in
            var t = topic
            t.messageIds.removeAll { pendingMessageIDs.contains($0) }
            return t
        }.filter { !$0.messageIds.isEmpty }
        try? SegmentationCache.save(
            CachedAnalysis(
                messageCount: messages.count,
                newestRowId: filedThrough,
                generatedAt: Date(),
                topics: saved,
                loops: loops
            ),
            chatId: chatId
        )
    }

    /// Merge freshly detected loops with stored ones, preserving the user's
    /// resolved/dismissed decisions (matched case-insensitively by title).
    func mergeLoops(_ detected: [OpenLoop]) -> [OpenLoop] {
        var merged = loops // keep resolved/dismissed history
        for loop in detected {
            let exists = merged.contains {
                $0.title.caseInsensitiveCompare(loop.title) == .orderedSame
            }
            if !exists { merged.append(loop) }
        }
        return merged
    }

    func setLoopStatus(_ loop: OpenLoop, _ status: LoopStatus) {
        guard let index = loops.firstIndex(where: { $0.id == loop.id }) else { return }
        loops[index].status = status
        persistLoops()
    }

    private func persistLoops() {
        guard let chatId = settings.selectedChatRowID else { return }
        let cached = SegmentationCache.load(chatId: chatId)
        let analysis = CachedAnalysis(
            messageCount: cached?.messageCount ?? messages.count,
            newestRowId: cached?.newestRowId ?? lastSeenRowID,
            generatedAt: cached?.generatedAt ?? Date(),
            topics: cached?.topics ?? topics,
            loops: loops
        )
        try? SegmentationCache.save(analysis, chatId: chatId)
    }

    // MARK: - Sending

    func send(_ text: String) async {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canSend, !isSending else { return }
        let handle = settings.selectedHandleId
        // Replying inside a thread: tell the other side which subject this is, and
        // keep this message and the replies to it in the thread.
        if let topic = selectedTopic {
            if settings.prefixThreadReplies {
                trimmed = "Re: \(topic.title) — \(trimmed)"
            }
            activeThread = (topic.id, trimmed, Date())
        } else {
            activeThread = nil
        }
        isSending = true
        defer { isSending = false }
        do {
            // Detached: osascript is synchronous and must not block the UI.
            try await Task.detached {
                try MessageSender.send(text: trimmed, to: handle)
            }.value
            await pollOnce() // pick up our own message quickly
            scrollToken += 1
        } catch {
            notice = error.localizedDescription
        }
    }

    // MARK: - Search / navigation helpers

    func jumpToMessage(_ message: ChatMessage) {
        if let topic = topics.first(where: { $0.messageIds.contains(message.id) }) {
            sidebarSelection = .topic(topic.id)
        } else {
            sidebarSelection = .all
        }
        searchText = ""
        jumpToMessageID = message.id
    }

    func topicTitle(for message: ChatMessage) -> String? {
        topics.first(where: { $0.messageIds.contains(message.id) })?.title
    }

    func isFirstOfDay(_ index: Int, in list: [ChatMessage]) -> Bool {
        guard index >= 0, index < list.count else { return false }
        if index == 0 { return true }
        let calendar = Calendar.current
        return !calendar.isDate(list[index].date, inSameDayAs: list[index - 1].date)
    }

    func dismissNotice() { notice = nil }
}
