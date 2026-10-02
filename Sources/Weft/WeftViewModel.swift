import Foundation
import AppKit

// MARK: - WeftViewModel

/// @MainActor UI state. All SQLite access goes through the ChatDBReader actor;
/// all sends go through MessageSender (detached so osascript never blocks UI).
@MainActor @Observable
final class WeftViewModel {
    let settings = AppSettings.shared
    /// Sorts the conversations you aren't looking at.
    let background = BackgroundSorter()

    /// Added conversations, in the order added (for the sidebar switcher).
    var followedChats: [ChatInfo] {
        settings.followedChats.compactMap { id in chats.first { $0.id == id } }
    }

    /// Older-history sorting progress (nil when not running).
    var historyProgress: (done: Int, total: Int)?
    /// Why older-history sorting stopped, if it failed.
    var historyError: String?
    private var backfillTask: Task<Void, Never>?

    /// New incoming messages in the open conversation while Weft wasn't in front.
    var openUnread = 0
    /// First-time setup: the notifications step.
    var showNotificationSetup = false

    /// Group chats show who said what.
    var isGroupChat: Bool { settings.selectedHandleId.contains(",") }

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

    /// Changes whenever the open conversation changes. Every AI call
    /// remembers the session it started in and throws its result away if
    /// the session has moved on — so a slow sort for conversation A can
    /// never land in conversation B.
    private(set) var session = UUID()

    /// A new conversation was opened (or the open one removed): anything
    /// still running for the previous one is discarded when it returns.
    func startNewSession() { session = UUID() }

    /// Unsent text per conversation, kept across switching, searching and
    /// failed sends.
    var drafts: [Int64: String] = [:] {
        didSet { UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: drafts.map { (String($0.key), $0.value) }), forKey: "weft.drafts") }
    }
    var currentDraft: String {
        get { settings.selectedChatRowID.flatMap { drafts[$0] } ?? "" }
        set { if let id = settings.selectedChatRowID { drafts[id] = newValue.isEmpty ? nil : newValue } }
    }

    /// First sort of a conversation waits for your OK (which AI, how much).
    var firstSortRequest: ChatInfo?

    /// A notice's optional "Retry"/"Sort" button (only for that notice).
    struct NoticeAction { let forText: String; let label: String; let run: @MainActor () -> Void }
    var noticeAction: NoticeAction?
    func showNotice(_ text: String, action label: String? = nil, run: (@MainActor () -> Void)? = nil) {
        notice = text
        noticeAction = (label != nil && run != nil) ? NoticeAction(forText: text, label: label!, run: run!) : nil
    }

    private var pollTask: Task<Void, Never>?
    private var watcher: ChatDBWatcher?
    private var isPolling = false
    private var autoSortTask: Task<Void, Never>?
    private var lastSeenRowID: Int64 = 0
    /// Newest reaction row applied (reactions are separate rows in chat.db).
    private var lastReactionRowID: Int64 = 0
    /// Where each pending message is shown until Claude files it.
    private var provisionalTopic: [Int64: UUID] = [:]
    /// The thread you last replied in from this app. Your own reply goes
    /// straight into it; replies after it are filed by Claude with this
    /// thread as the likely home, until you reply elsewhere, send from your
    /// phone, or 30 minutes pass.
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
    /// One-to-one: send to the person. Group: send to the chat itself, which
    /// reaches the whole group.
    var canSend: Bool {
        if isGroupChat { return !(selectedChat?.guid ?? "").isEmpty }
        return !settings.selectedHandleId.isEmpty
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

    /// Search scope: just the open conversation, or every added one.
    var searchAllConversations = false

    /// Open a search result from any conversation.
    func jumpToMessage(_ message: ChatMessage, inChat chat: Int64) async {
        if chat != settings.selectedChatRowID, let info = chats.first(where: { $0.id == chat }) {
            await selectChat(info)
        }
        if let loaded = messages.first(where: { $0.id == message.id }) { jumpToMessage(loaded) }
    }

    var searchResults: [ChatMessage] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return messages.filter { $0.text.localizedCaseInsensitiveContains(q) }.suffix(200).reversed()
    }

    // MARK: - Lifecycle

    static let noAIMessage = "No AI is set up to sort messages yet. Open Settings (gear icon) and pick one."

    func startup() async {
        if let saved = UserDefaults.standard.dictionary(forKey: "weft.drafts") as? [String: String] {
            drafts = Dictionary(uniqueKeysWithValues: saved.compactMap { k, v in Int64(k).map { ($0, v) } })
        }
        background.onChange = { [weak self] in self?.updateBadge() }
        background.conversationName = { [weak self] id in
            self?.chats.first { $0.id == id }.map { ContactNames.shared.shortDisplay($0.participants) } ?? "Messages"
        }
        // Coming back to Weft = you've now seen the open conversation.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didBecomeActive() }
        }
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
            // Don't announce messages that were already there at launch.
            for id in settings.followedChats {
                if let latest = try? await reader.latestMessageRowID(chatRowID: id) {
                    Notifier.shared.seed(chat: id, through: latest)
                }
            }
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
        startNewSession()
        firstSortRequest = nil
        settings.selectedChatRowID = chat.id
        if !settings.followedChats.contains(chat.id) { settings.followedChats.append(chat.id) }
        background.markRead(chat.id)
        openUnread = 0
        // First-time setup: ask about notifications after the first pick.
        if !settings.notificationsOnboarded { showNotificationSetup = true }
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
            messages = try await Self.withAttachments(ChatDBReader.shared.fetchMessages(chatRowID: chat.id).map(Self.labeled), chat: chat.id)
            lastSeenRowID = messages.last?.id ?? 0
            settings.markViewed(chat: chat.id, through: messages.map(\.id).max() ?? 0)
            lastReactionRowID = 0
            await applyNewReactions(chatRowID: chat.id)
            pendingMessageIDs = []
            provisionalTopic = [:]
            // Restore the saved topics, then file anything that arrived while
            // the app was closed. No saved topics yet -> one full sort.
            if let cached = SegmentationCache.load(chatId: chat.id), !cached.topics.isEmpty {
                topics = cached.topics
                loops = cached.loops
                let filed = Set(cached.topics.flatMap(\.messageIds))
                showProvisionally(messages.filter { $0.id > cached.newestRowId && !filed.contains($0.id) })
                if !pendingMessageIDs.isEmpty { scheduleAutoSort(after: 0) }
            } else if !messages.isEmpty {
                // First time for this conversation: ask before uploading it.
                if settings.consentedChats.contains(chat.id) {
                    scheduleAutoSort(after: 0)
                } else {
                    firstSortRequest = chat
                }
            }
            scrollToken += 1
            startPolling()
            startHistoryBackfill()
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
        backfillTask?.cancel()
        backfillTask = nil
        historyProgress = nil
        historyError = nil
    }

    func pollOnce() async {
        guard let chatId = settings.selectedChatRowID, !isPolling else { return }
        isPolling = true
        defer { isPolling = false }
        do {
            let known = Set(messages.map(\.id))
            // Other added conversations get checked too (debounced).
            background.schedule(settings: settings) { [weak self] in self?.settings.selectedChatRowID }
            let fresh = try await Self.withAttachments(ChatDBReader.shared
                .fetchMessages(chatRowID: chatId, after: lastSeenRowID)
                .filter { !known.contains($0.id) }
                .map(Self.labeled), chat: chatId, after: lastSeenRowID)
            if !fresh.isEmpty {
                messages.append(contentsOf: fresh)
                lastSeenRowID = max(lastSeenRowID, fresh.map(\.id).max() ?? 0)
                if NSApp.isActive {
                    settings.markViewed(chat: chatId, through: lastSeenRowID)
                } else {
                    // Not in front: count it and announce it.
                    openUnread += fresh.filter { !$0.isFromMe }.count
                    Notifier.shared.announce(fresh, chat: chatId,
                                             conversationName: selectedChat.map { ContactNames.shared.shortDisplay($0.participants) } ?? "Messages",
                                             settings: settings)
                    updateBadge()
                }
            }
            // Reactions can arrive on their own, after the message they're on.
            await applyNewReactions(chatRowID: chatId)
            guard !fresh.isEmpty else { return }
            let unfiled = fileIntoActiveThread(fresh)
            if !unfiled.isEmpty {
                showProvisionally(unfiled)
                // Your own sent message: file it right away. Incoming
                // messages: short pause so a burst of replies is filed in
                // one call. (A reply that lands mid-filing waits its turn.)
                scheduleAutoSort(after: unfiled.allSatisfy(\.isFromMe) ? 0 : 3)
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
        guard !messages.isEmpty, let myChat = settings.selectedChatRowID, !isAnalyzing else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }
        let mySession = session
        let snapshot = messages
        guard let client = settings.makeClient() else {
            notice = Self.noAIMessage
            return
        }
        do {
            async let segmented = TopicSegmenter(client: client).segment(messages: snapshot)
            async let detected = Self.capture { try await OpenLoopDetector(client: client).detect(messages: snapshot) }
            let newTopics = try await segmented
            let detection = await detected
            guard mySession == session else { return }   // conversation changed meanwhile
            switch detection {
            case .success(let newLoops):
                let previouslyOpen = loops.filter { $0.status == .open }
                loops = mergeLoops(newLoops)
                await reconcile(previouslyOpen: previouslyOpen, stillDetected: newLoops, client: client, session: mySession)
            case .failure(let error):
                showNotice("Couldn't check follow-ups: \(error.localizedDescription)", action: "Retry") { [weak self] in
                    Task { await self?.retryFollowUps() }
                }
            }
            guard mySession == session else { return }
            let covered = Set(snapshot.map(\.id))
            topics = newTopics
            // Anything that arrived during the sort is still pending.
            pendingMessageIDs = pendingMessageIDs.subtracting(covered)
            provisionalTopic = provisionalTopic.filter { !covered.contains($0.key) }
            showProvisionally(messages.filter { pendingMessageIDs.contains($0.id) })
            sortTopicsByActivity()
            topicsStale = false
            saveCache(chat: myChat, filedThrough: snapshot.map(\.id).max() ?? 0)
        } catch {
            guard mySession == session else { return }
            topicsStale = true
            showNotice("Sorting failed: \(error.localizedDescription)", action: "Retry") { [weak self] in
                Task { await self?.analyze() }
            }
        }
        if !pendingMessageIDs.isEmpty { scheduleAutoSort(after: 3) }
        startHistoryBackfill()
    }

    /// Run an async throwing job and keep its error instead of throwing.
    private static func capture<T: Sendable>(_ job: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await job()) } catch { return .failure(error) }
    }

    /// Re-sort: follow-ups that were open before but weren't found again
    /// may have been settled. Ask once and close those that were. Ones you
    /// marked yourself (resolved/dismissed) are never touched.
    private func reconcile(previouslyOpen: [OpenLoop], stillDetected: [OpenLoop], client: LLMClient, session mySession: UUID) async {
        let found = Set(stillDetected.map { $0.title.lowercased() })
        let toCheck = previouslyOpen.filter { !found.contains($0.title.lowercased()) }
        guard !toCheck.isEmpty else { return }
        let earliest = toCheck.compactMap(\.sourceMessageId).min() ?? 0
        let later = messages.filter { $0.id > earliest }
        guard !later.isEmpty,
              let resolved = try? await OpenLoopDetector(client: client).resolvedLater(loops: toCheck, laterMessages: later),
              mySession == session else { return }
        for i in loops.indices where loops[i].status == .open && resolved.contains(loops[i].id) {
            loops[i].status = .resolved
        }
    }

    // MARK: - Per-conversation sorting controls

    func isPaused(_ chat: Int64) -> Bool { settings.pausedChats.contains(chat) }

    func setPaused(_ chat: Int64, _ paused: Bool) {
        if paused {
            settings.pausedChats.insert(chat)
            if chat == settings.selectedChatRowID {
                autoSortTask?.cancel()
                backfillTask?.cancel()
                backfillTask = nil
                historyProgress = nil
            }
        } else {
            settings.pausedChats.remove(chat)
            if chat == settings.selectedChatRowID {
                if !pendingMessageIDs.isEmpty || topics.isEmpty { scheduleAutoSort(after: 0) }
                startHistoryBackfill()
            }
        }
    }

    func setRecentOnly(_ chat: Int64, _ recentOnly: Bool) {
        if recentOnly {
            settings.recentOnlyChats.insert(chat)
            if chat == settings.selectedChatRowID { backfillTask?.cancel(); backfillTask = nil; historyProgress = nil }
        } else {
            settings.recentOnlyChats.remove(chat)
            if chat == settings.selectedChatRowID { startHistoryBackfill() }
        }
    }

    /// "Retry" on the new-messages banner: file them again (not a full re-sort).
    func retryFiling() {
        topicsStale = false
        scheduleAutoSort(after: 0)
    }

    /// What Weft is doing right now, for the queue popover.
    struct QueueItem: Identifiable {
        let id = UUID()
        let conversation: String
        let status: String
        let symbol: String
    }

    var queue: [QueueItem] {
        var items: [QueueItem] = []
        let name = selectedChat.map { ContactNames.shared.shortDisplay($0.participants) } ?? "This conversation"
        if let chat = settings.selectedChatRowID {
            if settings.pausedChats.contains(chat) {
                items.append(.init(conversation: name, status: pendingMessageIDs.isEmpty ? "Sorting paused" : "Sorting paused — \(pendingMessageIDs.count) new waiting", symbol: "pause.circle"))
            } else if firstSortRequest != nil {
                items.append(.init(conversation: name, status: "Waiting for your OK to sort", symbol: "hand.raised"))
            } else if isAnalyzing && topics.isEmpty {
                items.append(.init(conversation: name, status: "First sort in progress", symbol: "arrow.triangle.2.circlepath"))
            } else if !pendingMessageIDs.isEmpty {
                items.append(.init(conversation: name, status: "Filing \(pendingMessageIDs.count) new message\(pendingMessageIDs.count == 1 ? "" : "s")", symbol: "tray.and.arrow.down"))
            }
            if let p = historyProgress, p.total > 0 {
                items.append(.init(conversation: name, status: "Sorting older history — \(Int(Double(p.done) / Double(p.total) * 100))%", symbol: "clock.arrow.circlepath"))
            }
            if let err = historyError {
                items.append(.init(conversation: name, status: "Older history stopped: \(err)", symbol: "exclamationmark.triangle"))
            }
        }
        if let busy = background.working, let chat = chats.first(where: { $0.id == busy }) {
            items.append(.init(conversation: ContactNames.shared.shortDisplay(chat.participants), status: "Filing new messages in the background", symbol: "tray.and.arrow.down"))
        }
        for id in settings.followedChats where id != settings.selectedChatRowID && settings.pausedChats.contains(id) {
            if let chat = chats.first(where: { $0.id == id }) {
                items.append(.init(conversation: ContactNames.shared.shortDisplay(chat.participants), status: "Sorting paused", symbol: "pause.circle"))
            }
        }
        return items
    }

    /// "Retry" after the follow-up check failed.
    func retryFollowUps() async {
        guard let myChat = settings.selectedChatRowID, !isAnalyzing, let client = settings.makeClient() else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }
        let mySession = session
        do {
            let newLoops = try await OpenLoopDetector(client: client).detect(messages: messages)
            guard mySession == session else { return }
            let previouslyOpen = loops.filter { $0.status == .open }
            loops = mergeLoops(newLoops)
            await reconcile(previouslyOpen: previouslyOpen, stillDetected: newLoops, client: client, session: mySession)
            guard mySession == session else { return }
            notice = nil
            saveCache(chat: myChat, filedThrough: Self.checkpoint(messages: messages, pending: pendingMessageIDs))
        } catch {
            guard mySession == session else { return }
            showNotice("Couldn't check follow-ups: \(error.localizedDescription)", action: "Retry") { [weak self] in
                Task { await self?.retryFollowUps() }
            }
        }
    }

    /// First-sort consent given: remember it and start.
    func approveFirstSort() {
        guard let chat = firstSortRequest else { return }
        settings.consentedChats.insert(chat.id)
        firstSortRequest = nil
        notice = nil
        scheduleAutoSort(after: 0)
    }

    /// "Not now" on the first-sort question.
    func postponeFirstSort() {
        guard let chat = firstSortRequest else { return }
        firstSortRequest = nil
        showNotice("This conversation isn't sorted yet.", action: "Sort…") { [weak self] in
            self?.firstSortRequest = chat
        }
    }

    /// Newest message that can be marked "sorted": never past a message
    /// still waiting to be filed, so nothing is lost if Weft quits.
    static func checkpoint(messages: [ChatMessage], pending: Set<Int64>) -> Int64 {
        let filed = messages.map(\.id).filter { !pending.contains($0) }.max() ?? 0
        guard let firstPending = pending.min() else { return filed }
        return min(filed, firstPending - 1)
    }

    // MARK: - Editing topics by hand (with Undo)

    /// Apply a hand correction, save it, and register Undo/Redo (Edit menu,
    /// ⌘Z / ⇧⌘Z). Later sorting only adds new messages, so corrections
    /// stick — until a full Re-sort Everything.
    func editTopics(_ actionName: String, undoManager: UndoManager?, _ change: ([Topic]) -> [Topic]) {
        guard let chat = settings.selectedChatRowID else { return }
        let before = topics
        let after = change(before)
        guard after != before else { return }
        applyEdit(after, chat: chat)
        registerEditUndo(actionName, undoManager: undoManager, chat: chat, restore: before, redo: after)
    }

    private func applyEdit(_ newTopics: [Topic], chat: Int64) {
        topics = newTopics
        sortTopicsByActivity()
        if case .topic(let id)? = sidebarSelection, !topics.contains(where: { $0.id == id }) {
            sidebarSelection = .all
        }
        saveCache(chat: chat, filedThrough: Self.checkpoint(messages: messages, pending: pendingMessageIDs))
    }

    private func registerEditUndo(_ name: String, undoManager: UndoManager?, chat: Int64, restore: [Topic], redo: [Topic]) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { vm in
            MainActor.assumeIsolated {
                // Only undo into the conversation the edit was made in.
                guard vm.settings.selectedChatRowID == chat else { return }
                vm.applyEdit(restore, chat: chat)
                vm.registerEditUndo(name, undoManager: undoManager, chat: chat, restore: redo, redo: restore)
            }
        }
        undoManager.setActionName(name)
    }

    // MARK: - Older history

    /// Messages in the open conversation that no thread holds yet (and that
    /// aren't new messages waiting to be filed) — the part of a long
    /// history the first sort couldn't fit.
    private func unsortedHistory() -> [ChatMessage] {
        let filed = Set(topics.flatMap(\.messageIds))
        return messages.filter { !filed.contains($0.id) && !pendingMessageIDs.contains($0.id) }
    }

    /// Sort older history in the background, a chunk at a time, newest
    /// first, into the existing threads (or new ones). New messages always
    /// go first: this waits whenever something new is being filed.
    func startHistoryBackfill() {
        guard settings.sortOlderHistory, backfillTask == nil, !topics.isEmpty,
              let chat = settings.selectedChatRowID, historyError == nil,
              !settings.pausedChats.contains(chat), !settings.recentOnlyChats.contains(chat) else { return }
        let chatAtStart = settings.selectedChatRowID
        backfillTask = Task { [weak self] in
            await self?.runBackfill(chat: chatAtStart)
            self?.backfillTask = nil
            self?.historyProgress = nil
        }
    }

    private func runBackfill(chat: Int64?) async {
        let mySession = session
        historyError = nil
        let total = unsortedHistory().count
        guard total > 0 else {
            await checkHistoryLoops()
            return
        }
        while !Task.isCancelled, mySession == session, settings.sortOlderHistory,
              let c = chat, !settings.pausedChats.contains(c), !settings.recentOnlyChats.contains(c) {
            let remaining = unsortedHistory()
            if remaining.isEmpty {
                await checkHistoryLoops()
                return
            }
            historyProgress = (total - remaining.count, total)
            // New messages first.
            if isAnalyzing || !pendingMessageIDs.isEmpty {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            guard var client = settings.makeClient() else { return }
            client.effort = "low"

            // Oldest unsorted messages first, so each chunk can see (and
            // close) the loops raised before it.
            let local = settings.provider?.isLocal ?? false
            let maxCount = local ? 40 : 120
            let maxChars = local ? 8_000 : 40_000
            var chunk: [ChatMessage] = []
            var chars = 0
            for m in remaining {
                let size = min(m.text.count, 2_000) + 40
                if !chunk.isEmpty && (chunk.count >= maxCount || chars + size > maxChars) { break }
                chunk.append(m); chars += size
            }
            guard let firstInChunk = chunk.first, let lastInChunk = chunk.last else { return }

            // Threads nearest in time to this chunk (the oldest ones).
            let candidates = Array(topics.sorted { ($0.messageIds.min() ?? 0) < ($1.messageIds.min() ?? 0) }.prefix(60))
            let titleByID = Dictionary(candidates.flatMap { t in t.messageIds.map { ($0, t.title) } }, uniquingKeysWith: { a, _ in a })
            // Context: the already-sorted messages just before this chunk.
            let context = messages.filter { $0.id < firstInChunk.id && titleByID[$0.id] != nil }.suffix(12)
                .map { ($0, titleByID[$0.id]!) }
            // Loops raised earlier in old history that this chunk might close.
            let historyLoops = loops.filter { $0.status == .open && $0.needsLaterCheck == true }

            isAnalyzing = true
            let result: TopicFiler.Result
            do {
                result = try await TopicFiler(client: client).file(
                    newMessages: chunk, context: Array(context), topics: candidates,
                    openLoops: historyLoops, purpose: .history
                )
            } catch {
                isAnalyzing = false
                historyError = error.localizedDescription
                return
            }
            isAnalyzing = false
            guard !Task.isCancelled, mySession == session else { return }

            let already = Set(topics.flatMap(\.messageIds))
            var placed = 0
            for a in result.assignments {
                let ids = a.messageIds.filter { !already.contains($0) }
                guard !ids.isEmpty else { continue }
                if let i = a.topicIndex, let target = topics.firstIndex(where: { $0.id == candidates[i].id }) {
                    topics[target].messageIds.append(contentsOf: ids)
                    topics[target].messageIds.sort()
                    // Only if this chunk holds the thread's newest messages —
                    // old news mustn't overwrite a current summary.
                    if let s = a.updatedSummary, !s.isEmpty,
                       lastInChunk.id >= (topics[target].messageIds.max() ?? 0) {
                        topics[target].summary = s
                    }
                } else {
                    topics.append(Topic(id: UUID(), title: a.newTitle, summary: a.newSummary, messageIds: ids))
                }
                placed += ids.count
            }
            // Anything the AI skipped joins the thread of the message before
            // it (or after, at the very start), so the loop always progresses.
            if placed < chunk.count {
                for m in chunk where !Set(topics.flatMap(\.messageIds)).contains(m.id) {
                    let target = topics.firstIndex(where: { $0.messageIds.contains { $0 < m.id } })
                        ?? topics.firstIndex(where: { $0.messageIds.contains { $0 > m.id } })
                    if let target {
                        topics[target].messageIds.append(m.id)
                        topics[target].messageIds.sort()
                    }
                }
            }

            // Open loops: close the ones this chunk resolved; add new ones,
            // marked to be checked against the later conversation.
            let resolved = Set(result.resolvedLoopIDs)
            for i in loops.indices where resolved.contains(loops[i].id) {
                loops[i].status = .resolved
                loops[i].needsLaterCheck = nil
            }
            for var loop in result.newLoops where !loops.contains(where: { $0.title.caseInsensitiveCompare(loop.title) == .orderedSame }) {
                loop.needsLaterCheck = true
                loops.append(loop)
            }

            sortTopicsByActivity()
            if let chat { saveCache(chat: chat, filedThrough: Self.checkpoint(messages: messages, pending: pendingMessageIDs)) }
        }
    }

    /// Loops raised in old history may have been resolved later in the
    /// conversation. One check against the later messages closes those.
    private func checkHistoryLoops() async {
        let chat = settings.selectedChatRowID
        let mySession = session
        let pending = loops.filter { $0.status == .open && $0.needsLaterCheck == true }
        guard !pending.isEmpty, var client = settings.makeClient() else { return }
        client.effort = "low"
        let earliest = pending.compactMap(\.sourceMessageId).min() ?? 0
        let later = messages.filter { $0.id > earliest }
        guard !later.isEmpty else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            let resolved = try await OpenLoopDetector(client: client).resolvedLater(loops: pending, laterMessages: later)
            guard mySession == session else { return }
            for i in loops.indices where pending.contains(where: { $0.id == loops[i].id }) {
                if resolved.contains(loops[i].id) { loops[i].status = .resolved }
                loops[i].needsLaterCheck = nil
            }
            if let chat { saveCache(chat: chat, filedThrough: Self.checkpoint(messages: messages, pending: pendingMessageIDs)) }
        } catch {
            guard mySession == session else { return }
            historyError = error.localizedDescription
        }
    }

    /// Settings / sidebar "Retry" after a history-sorting error.
    func retryHistory() {
        historyError = nil
        startHistoryBackfill()
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

    // MARK: - Notifications

    func updateBadge() {
        let total = background.unreadCounts.values.reduce(0, +) + openUnread
        Notifier.shared.setBadge(total, enabled: settings.dockBadge)
    }

    private func didBecomeActive() {
        guard let chat = settings.selectedChatRowID else { return }
        settings.markViewed(chat: chat, through: lastSeenRowID)
        openUnread = 0
        updateBadge()
    }

    /// A banner or reminder was clicked.
    func openConversation(_ id: Int64, loop: UUID? = nil) async {
        if settings.selectedChatRowID != id, let chat = chats.first(where: { $0.id == id }) { await selectChat(chat) }
        if let loop, loops.contains(where: { $0.id == loop }) { sidebarSelection = .loop(loop) }
    }

    // MARK: - Conversations

    /// Attach photos and files to their messages.
    static func withAttachments(_ messages: [ChatMessage], chat: Int64, after: Int64 = 0) async -> [ChatMessage] {
        guard let byMessage = try? await ChatDBReader.shared.fetchAttachments(chatRowID: chat, after: after),
              !byMessage.isEmpty else { return messages }
        return messages.map { m in
            var m = m
            m.attachments = byMessage[m.id] ?? []
            return m
        }
    }

    /// Open this conversation in Messages. One-to-one conversations open to
    /// that person; for group chats Messages itself opens (there's no
    /// public way to open a specific group).
    func openInMessages(_ chat: ChatInfo? = nil) {
        guard let chat = chat ?? selectedChat else { return }
        let handles = chat.participants.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if handles.count == 1, let handle = handles.first,
           let url = URL(string: (chat.service == "SMS" ? "sms:" : "imessage:") + handle) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Messages.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Contact name (or number) on each incoming message, for group chats
    /// and for the AI transcript.
    static func labeled(_ m: ChatMessage) -> ChatMessage {
        var m = m
        m.senderName = BackgroundSorter.senderName(m)
        return m
    }

    /// Refresh the list of all conversations (for the picker).
    func reloadChats() async {
        if let fresh = try? await ChatDBReader.shared.listChats() { chats = fresh }
    }

    /// Stop following a conversation. Its saved threads are kept, so adding
    /// it back later is instant.
    func removeConversation(_ id: Int64) async {
        settings.followedChats.removeAll { $0 == id }
        background.markRead(id)
        guard settings.selectedChatRowID == id else { return }
        if let next = followedChats.first {
            await selectChat(next)
        } else {
            stopPolling()
            startNewSession()
            settings.selectedChatRowID = nil
            messages = []; topics = []; loops = []
            showChatPicker = true
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
            // Match on who reacted, so in a group one person's reaction
            // doesn't replace someone else's.
            if event.isRemoval {
                reactions.removeAll { $0.sender == event.sender && $0.emoji == event.emoji }
            } else {
                // A person's new reaction replaces their previous one.
                reactions.removeAll { $0.sender == event.sender }
                reactions.append(Reaction(emoji: event.emoji, isFromMe: event.isFromMe, sender: event.sender))
            }
            messages[i].reactions = reactions
        }
    }

    // MARK: - Automatic filing

    /// Puts your own reply straight into the thread you sent it from.
    /// Returns the messages that still need Claude to file them (others'
    /// replies are filed with that thread as the likely home).
    private func fileIntoActiveThread(_ fresh: [ChatMessage]) -> [ChatMessage] {
        guard let chatId = settings.selectedChatRowID else { return fresh }
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
            // Your own reply from this thread: certain, no call needed.
            if message.isFromMe {
                if !topics[index].messageIds.contains(message.id) {
                    topics[index].messageIds.append(message.id)
                }
            } else {
                unfiled.append(message)
            }
        }
        sortTopicsByActivity()
        saveCache(chat: chatId, filedThrough: Self.checkpoint(messages: messages, pending: pendingMessageIDs.union(unfiled.map(\.id))))
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
        // Paused: new messages stay shown but nothing goes to the AI.
        if let chat = settings.selectedChatRowID, settings.pausedChats.contains(chat) { return }
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
        let allPending = messages.filter { pendingMessageIDs.contains($0.id) }
        guard !allPending.isEmpty, let myChat = settings.selectedChatRowID else { return }
        // Oldest first, and no more than this AI can take in one call —
        // the rest wait for the next pass.
        let batch = Self.batch(allPending, local: settings.provider?.isLocal ?? false)
        isAnalyzing = true
        defer { isAnalyzing = false }
        let mySession = session

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
        let openLoops = loops.filter { $0.status == .open }
        // Just replied in a thread? Point Claude at it (it can still pick another).
        var preferred: Int?
        if let thread = activeThread, Date().timeIntervalSince(thread.at) < 30 * 60 {
            preferred = candidates.firstIndex(where: { $0.id == thread.topicID })
        }

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
                openLoops: openLoops,
                preferredTopic: preferred
            )
            guard mySession == session else { return }   // conversation changed meanwhile
            // Rebuild from the topics as they are now (others may have been
            // filed while we waited), minus provisional placements.
            base = topics.map { topic -> Topic in
                var t = topic
                t.messageIds.removeAll { pendingMessageIDs.contains($0) }
                return t
            }.filter { !$0.messageIds.isEmpty }
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
            let resolved = Set(result.resolvedLoopIDs)
            for i in loops.indices where loops[i].status == .open && resolved.contains(loops[i].id) {
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
            saveCache(chat: myChat, filedThrough: Self.checkpoint(messages: messages, pending: pendingMessageIDs))
            if !pendingMessageIDs.isEmpty {
                // More waiting (a later batch, or skipped): go again.
                scheduleAutoSort(after: filed.isSuperset(of: batchIDs) ? 0 : 3)
            }
        } catch {
            guard mySession == session else { return }
            topicsStale = true
            showNotice("Couldn't sort new messages: \(error.localizedDescription)", action: "Retry") { [weak self] in
                self?.scheduleAutoSort(after: 0)
            }
        }
    }

    /// The oldest pending messages that fit one AI call.
    static func batch(_ pending: [ChatMessage], local: Bool) -> [ChatMessage] {
        let maxCount = local ? 40 : 120
        let maxChars = local ? 8_000 : 40_000
        var out: [ChatMessage] = []
        var chars = 0
        for m in pending {
            let size = min(m.text.count, 2_000) + 40
            if !out.isEmpty && (out.count >= maxCount || chars + size > maxChars) { break }
            out.append(m); chars += size
        }
        return out
    }

    /// Most recently active topic first (Mail-style).
    private func sortTopicsByActivity() {
        topics.sort { ($0.messageIds.max() ?? 0) > ($1.messageIds.max() ?? 0) }
    }

    private func saveCache(chat chatId: Int64, filedThrough: Int64) {
        // Don't save provisional placements — they get re-filed on next launch.
        let saved = topics.map { topic -> Topic in
            var t = topic
            t.messageIds.removeAll { pendingMessageIDs.contains($0) }
            return t
        }.filter { !$0.messageIds.isEmpty }
        try? SegmentationCache.save(
            CachedAnalysis(
                messageCount: messages.count,
                newestRowId: min(filedThrough, Self.checkpoint(messages: messages, pending: pendingMessageIDs)),
                generatedAt: Date(),
                topics: saved,
                loops: loops
            ),
            chatId: chatId
        )
        if chatId == settings.selectedChatRowID { syncReminders() }
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
        updateLoop(loop.id) { $0.status = status }
    }

    /// Change one follow-up (owner, due date, snooze…), save, and refresh
    /// its reminder.
    func updateLoop(_ id: UUID, _ change: (inout OpenLoop) -> Void) {
        guard let index = loops.firstIndex(where: { $0.id == id }) else { return }
        change(&loops[index])
        persistLoops()
    }

    /// Snooze presets: later today (+3h), tomorrow 9:00, next week 9:00.
    func snooze(_ loop: OpenLoop, until date: Date) {
        updateLoop(loop.id) { $0.snoozedUntil = date }
        if sidebarSelection == .loop(loop.id) { sidebarSelection = .all }
    }

    /// Keep this conversation's reminder notifications in step with its
    /// follow-ups (due dates and snoozes in the future, open ones only).
    func syncReminders() {
        guard let chat = settings.selectedChatRowID else { return }
        let name = selectedChat.map { ContactNames.shared.shortDisplay($0.participants) } ?? "Weft"
        Notifier.shared.syncReminders(loops: loops, chat: chat, conversationName: name, settings: settings)
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
        syncReminders()
    }

    // MARK: - Sending

    /// Returns false if the message wasn't sent.
    @discardableResult
    func send(_ text: String) async -> Bool {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canSend, !isSending else { return false }
        let handle = settings.selectedHandleId
        let groupChatGuid = isGroupChat ? selectedChat?.guid : nil
        let groupService = selectedChat?.service ?? ""
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
                if let groupChatGuid, !groupChatGuid.isEmpty {
                    try MessageSender.send(text: trimmed, toChat: groupChatGuid, service: groupService)
                } else {
                    try MessageSender.send(text: trimmed, to: handle)
                }
            }.value
            await pollOnce() // pick up our own message quickly
            scrollToken += 1
            return true
        } catch {
            notice = error.localizedDescription
            return false
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

    func dismissNotice() { notice = nil; noticeAction = nil }
}
