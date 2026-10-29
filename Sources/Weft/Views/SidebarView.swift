import SwiftUI

/// Thread list. Rows are explicit buttons that set the selection directly,
/// rather than relying on List's own selection handling.
struct SidebarView: View {
    @Bindable var viewModel: WeftViewModel
    @Environment(\.undoManager) private var undoManager
    @Environment(\.conversationPalette) private var palette
    @State private var renaming: Topic?
    @State private var showDone = false
    @State private var showSnoozed = false
    @State private var renameText = ""
    /// The open conversation, as the list's own selection. Letting the list
    /// handle clicks (no click handler on the rows) is what lets it start a
    /// drag to reorder, the way Finder's and Mail's sidebars work.
    @State private var chatSelection: Int64?
    /// Topic and follow-up counts of the conversations that aren't open,
    /// read from what Weft saved for them (the open one comes live from
    /// the view model).
    @State private var savedCounts: [Int64: ConversationCounts] = [:]

    var body: some View {
        List(selection: $chatSelection) {
            // Every added conversation, in your order (drag to reorder, or
            // right-click → Move Up / Move Down).
            // Right-click a conversation for more options.
            Section {
                ForEach(viewModel.followedChats) { chat in
                    let chatPalette = ConversationColors.palette(forChat: chat.id, settings: viewModel.settings)
                    let isOpen = viewModel.settings.selectedChatRowID == chat.id
                    ConversationRow(isSelected: isOpen, highlight: chatPalette.soft) {
                        // One person: their photo or initials. A group: the
                        // group symbol. Both in the conversation's hue.
                        Group {
                            if chat.participants.contains(",") {
                                Image(systemName: "person.3.fill")
                                    .foregroundStyle(chatPalette.tint)
                                    .scaledFont(.callout)
                            } else {
                                Avatar(handle: chat.participants, size: WeftStyle.runAvatarSize, tint: chatPalette.tint)
                            }
                        }
                        .frame(width: WeftStyle.runAvatarSize, height: WeftStyle.runAvatarSize)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ContactNames.shared.shortDisplay(chat.participants)).lineLimit(1)
                            // "4 topics · 2 follow-ups": what Weft has made
                            // of this conversation so far.
                            if let line = counts(for: chat, isOpen: isOpen)?.summary {
                                Text(line)
                                    .labelFont(.caption)
                                    .fontWeight(.regular)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        let count = isOpen
                            ? viewModel.openUnread
                            : (viewModel.background.unreadCounts[chat.id] ?? 0)
                        if count > 0 {
                            Text("\(count)")
                                .labelFont(.caption2, weight: .bold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(chatPalette.badge, in: Capsule())
                                .help(String(localized: "^[\(count) new message](inflect: true)"))
                        }
                    }
                    .tag(chat.id)
                    .contextMenu {
                        Button("Open") { Task { await viewModel.selectChat(chat) } }
                        Button("Open in Messages") { viewModel.openInMessages(chat) }
                        Divider()
                        Button("Move Up") { withAnimation { viewModel.moveConversation(chat.id, by: -1) } }
                            .disabled(viewModel.followedChats.first?.id == chat.id)
                        Button("Move Down") { withAnimation { viewModel.moveConversation(chat.id, by: 1) } }
                            .disabled(viewModel.followedChats.last?.id == chat.id)
                        Divider()
                        Button(viewModel.isPaused(chat.id) ? "Resume Sorting" : "Pause Sorting") {
                            viewModel.setPaused(chat.id, !viewModel.isPaused(chat.id))
                        }
                        Toggle("Skip Older History", isOn: Binding(
                            get: { viewModel.settings.recentOnlyChats.contains(chat.id) },
                            set: { viewModel.setRecentOnly(chat.id, $0) }
                        ))
                        Menu("Color") {
                            let chosen = viewModel.settings.hueIndex(forChat: chat.id)
                            Toggle("Automatic", isOn: Binding(
                                get: { chosen == nil },
                                set: { if $0 { viewModel.settings.setHueIndex(nil, forChat: chat.id) } }
                            ))
                            Divider()
                            ForEach(ConversationColors.all) { hue in
                                Toggle(hue.name, isOn: Binding(
                                    get: { chosen == hue.id },
                                    set: { if $0 { viewModel.settings.setHueIndex(hue.id, forChat: chat.id) } }
                                ))
                            }
                        }
                        Toggle("Add Topic to My Replies", isOn: Binding(
                            get: { viewModel.settings.prefixesReplies(chat: chat.id) },
                            set: { viewModel.settings.setPrefixesReplies($0, chat: chat.id) }
                        ))
                        Menu("Appearance") {
                            let chosen = viewModel.settings.appearance(forChat: chat.id)
                            Toggle("Automatic (as in Messages)", isOn: Binding(
                                get: { chosen == nil },
                                set: { if $0 { viewModel.settings.setAppearance(nil, forChat: chat.id) } }
                            ))
                            Divider()
                            Toggle("Light", isOn: Binding(
                                get: { chosen == "light" },
                                set: { if $0 { viewModel.settings.setAppearance("light", forChat: chat.id) } }
                            ))
                            Toggle("Dark", isOn: Binding(
                                get: { chosen == "dark" },
                                set: { if $0 { viewModel.settings.setAppearance("dark", forChat: chat.id) } }
                            ))
                        }
                        Divider()
                        Button("Remove from Weft", role: .destructive) {
                            Task { await viewModel.removeConversation(chat.id) }
                        }
                    }
                }
                .onMove { from, to in
                    // Reorder what's shown; keep any not-shown ids at the end.
                    var ids = viewModel.followedChats.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    viewModel.settings.followedChats = ids + viewModel.settings.followedChats.filter { !ids.contains($0) }
                }
            } header: {
                SectionHeader(String(localized: "Conversations")) {
                    Button {
                        viewModel.showChatPicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add a conversation")
                }
            }

            Section {
                SidebarRow(
                    isSelected: viewModel.sidebarSelection == .all || viewModel.sidebarSelection == nil,
                    action: { viewModel.sidebarSelection = .all }
                ) {
                    Label("All messages", systemImage: "tray.full")
                    Spacer()
                    CountText(count: viewModel.messages.count)
                }

                ForEach(viewModel.topics) { topic in
                    let isOpen = viewModel.sidebarSelection == .topic(topic.id)
                    SidebarRow(isSelected: isOpen, alignment: .top, action: { viewModel.openThread(topic.id) }) {
                        // The thread: a bar in the conversation's hue on the
                        // leading edge, strong on the open topic, faint on
                        // the rest. The same mark as the topic header.
                        ThreadBar(color: isOpen ? palette.tint : palette.tint.opacity(0.4))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(topic.title).lineLimit(1)
                                Spacer(minLength: 4)
                                if let date = viewModel.lastActivity(of: topic) {
                                    Text(RelativeTime.short(date))
                                        .labelFont(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .help(date.formatted(date: .abbreviated, time: .shortened))
                                }
                                // How many messages, when there are any.
                                CountText(count: topic.messageIds.count)
                            }
                            if !topic.summary.isEmpty {
                                Text(topic.summary)
                                    .scaledFont(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .contextMenu {
                        Button("Rename…") {
                            renameText = topic.title
                            renaming = topic
                        }
                        Menu("Merge Into") {
                            ForEach(viewModel.topics.filter { $0.id != topic.id }) { other in
                                Button(other.title) {
                                    viewModel.editTopics("Merge Topics", undoManager: undoManager) {
                                        TopicEditor.merge($0, topic.id, into: other.id)
                                    }
                                }
                            }
                        }
                        .disabled(viewModel.topics.count < 2)
                        Divider()
                        Button("Remove Topic") { viewModel.removeTopic(topic.id) }
                            .help("Removes this topic; its messages are sorted again into the right topics")
                    }
                }
            } header: {
                SectionHeader(String(localized: "Topics")) {
                    if let err = viewModel.historyError {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).scaledFont(.caption2)
                        Text("Couldn't sort older messages").scaledFont(.caption2).foregroundStyle(.secondary)
                            .help(err)
                        Button("Retry") { viewModel.retryHistory() }
                            .buttonStyle(.link).scaledFont(.caption2)
                    } else if let p = viewModel.historyProgress, p.total > 0 {
                        ProgressView().controlSize(.mini)
                        Text("Sorting older messages… \(Int(Double(p.done) / Double(p.total) * 100))%")
                            .scaledFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                // Re-checks once a minute so snoozes end and due dates turn
                // overdue on time.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let now = context.date
                    let open = viewModel.loops.filter { $0.status == .open }
                    let active = open.filter { !$0.isSnoozed(at: now) }
                    let snoozed = open.filter { $0.isSnoozed(at: now) }
                    let done = viewModel.loops.filter { $0.status != .open }
                    let waiting = active.filter { $0.owner != .me }
                    let owed = active.filter { $0.owner == .me }
                    VStack(alignment: .leading, spacing: 2) {
                        if active.isEmpty {
                            Text(viewModel.loops.isEmpty ? "None found yet." : "Nothing outstanding.")
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 6)
                        }
                        if !owed.isEmpty {
                            groupLabel(String(localized: "Owed by me"))
                            ForEach(owed) { loop in loopRow(loop, now: now) }
                        }
                        if !waiting.isEmpty {
                            groupLabel(String(localized: "Waiting on them"))
                            ForEach(waiting) { loop in loopRow(loop, now: now) }
                        }
                        if !snoozed.isEmpty {
                            expandRow(String(localized: "Snoozed (\(snoozed.count))"), isOpen: $showSnoozed)
                            if showSnoozed {
                                ForEach(snoozed) { loop in loopRow(loop, now: now) }
                            }
                        }
                        if !done.isEmpty {
                            expandRow(String(localized: "Done (\(done.count))"), isOpen: $showDone)
                            if showDone {
                                ForEach(done) { loop in loopRow(loop, now: now) }
                            }
                        }
                    }
                }
            } header: {
                SectionHeader(String(localized: "Follow-ups")) {
                    if viewModel.openLoopCount > 0 {
                        Text("\(viewModel.openLoopCount)")
                            .labelFont(.caption2, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(String(localized: "^[\(viewModel.openLoopCount) open follow-up](inflect: true)"))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Topic and follow-up counts for the conversations that aren't open,
        // from what Weft saved for them. Re-read when the list of
        // conversations changes and when another one is opened (the one
        // just left was live until now).
        .task(id: SavedCountsKey(chats: viewModel.followedChats.map(\.id), open: viewModel.settings.selectedChatRowID)) {
            savedCounts = Dictionary(uniqueKeysWithValues: viewModel.followedChats.compactMap { chat in
                SegmentationCache.load(chatId: chat.id).map {
                    (chat.id, ConversationCounts(topics: $0.topics.count, followUps: $0.loops.filter { $0.status == .open }.count))
                }
            })
        }
        // The list's selection highlight (the open conversation) in that
        // conversation's own colour.
        .tint(palette.tint)
        // Clicking a conversation selects it in the list; open it. And keep
        // the list in step when a conversation opens some other way (⌘1–9,
        // a search result, removing the open one).
        .onAppear { chatSelection = viewModel.settings.selectedChatRowID }
        .onChange(of: chatSelection) { _, id in
            guard let id, id != viewModel.settings.selectedChatRowID,
                  let chat = viewModel.followedChats.first(where: { $0.id == id }) else { return }
            Task { await viewModel.selectChat(chat) }
        }
        .onChange(of: viewModel.settings.selectedChatRowID) { _, id in
            if chatSelection != id { chatSelection = id }
        }
        .alert("Rename Topic", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Topic name", text: $renameText)
            Button("Rename") {
                if let topic = renaming {
                    viewModel.editTopics("Rename Topic", undoManager: undoManager) {
                        TopicEditor.rename($0, topic.id, to: renameText)
                    }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        // Wide enough that conversation names and thread titles fit.
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        .navigationTitle(viewModel.selectedChat.map { chatTitle($0) } ?? "Weft")
    }

    /// "Done (3)" / "Snoozed (1)": click anywhere on the row to show or
    /// hide the list.
    private func expandRow(_ title: String, isOpen: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isOpen.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .scaledFont(.caption, weight: .semibold)
                    .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
                Text(title)
                Spacer()
            }
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOpen.wrappedValue ? "expanded" : "collapsed")
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .scaledFont(.caption, weight: .semibold)
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
            .padding(.top, 4)
    }

    private func loopRow(_ loop: OpenLoop, now: Date = Date()) -> some View {
        SidebarRow(
            isSelected: viewModel.sidebarSelection == .loop(loop.id),
            action: { viewModel.sidebarSelection = .loop(loop.id) }
        ) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(loop.title).lineLimit(2)
                    if loop.status == .open, let due = loop.dueDate {
                        Text(loop.isOverdue(at: now)
                             ? String(localized: "Overdue · \(due.formatted(.dateTime.month(.abbreviated).day()))")
                             : String(localized: "Due \(due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"))
                            .labelFont(.caption2)
                            .foregroundStyle(loop.isOverdue(at: now) ? Color.red : Color.secondary)
                    }
                }
            } icon: {
                Image(systemName: loop.status == .open ? "circle" : (loop.status == .resolved ? "checkmark.circle" : "xmark.circle"))
                    .foregroundStyle(loop.isOverdue(at: now) ? Color.red : Color.primary)
            }
            .foregroundStyle(loop.status == .open ? .primary : .secondary)
            .accessibilityLabel(Text("\(loop.title), \(loop.status == .open ? String(localized: "open") : (loop.status == .resolved ? String(localized: "done") : String(localized: "dismissed")))"))
            Spacer()
        }
    }

    /// What to say under a conversation's name: live for the open one,
    /// saved for the others; nothing until Weft has sorted it.
    private func counts(for chat: ChatInfo, isOpen: Bool) -> ConversationCounts? {
        if isOpen, !viewModel.topics.isEmpty {
            return ConversationCounts(topics: viewModel.topics.count, followUps: viewModel.openLoopCount)
        }
        return savedCounts[chat.id]
    }

    private func chatTitle(_ chat: ChatInfo) -> String {
        chat.participants.isEmpty ? String(localized: "Conversation") : ContactNames.shared.display(chat.participants)
    }
}

/// Topics and open follow-ups of one conversation, for its sidebar row.
struct ConversationCounts: Equatable {
    let topics: Int
    let followUps: Int

    /// "4 topics · 2 follow-ups" (the follow-ups only when there are some).
    var summary: String {
        let topicsPart = topics == 1
            ? String(localized: "1 topic", comment: "Under a conversation's name")
            : String(localized: "\(topics) topics", comment: "Under a conversation's name")
        guard followUps > 0 else { return topicsPart }
        let loopsPart = followUps == 1
            ? String(localized: "1 follow-up", comment: "Under a conversation's name")
            : String(localized: "\(followUps) follow-ups", comment: "Under a conversation's name")
        return topicsPart + " · " + loopsPart
    }
}

private struct SavedCountsKey: Equatable {
    let chats: [Int64]
    let open: Int64?
}

/// "CONVERSATIONS", "TOPICS": small, spaced capitals with room on the right
/// for a button or a status.
private struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .textCase(.uppercase)
                .labelFont(.caption2, weight: .semibold)
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .accessibilityLabel(title)
            Spacer()
            trailing()
        }
        .padding(.bottom, 2)
    }
}

/// Conversation row: same look as SidebarRow. No click handler: the list's
/// own selection opens it, which also lets the list drag it to reorder.
private struct ConversationRow<Content: View>: View {
    let isSelected: Bool
    /// Selection colour: this conversation's own.
    let highlight: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 10) { content() }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .fontWeight(isSelected ? .semibold : .regular)
            // Our own highlight in the conversation's colour, in place of
            // the list's. The list's own changed with window focus (grey
            // when another window was in front) and blended oddly with the
            // tint; this one is the same soft fill as the topic rows.
            .listRowBackground(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? highlight : Color.clear)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
            )
            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
            // VoiceOver: one element, activates like a button. Keyboard:
            // Conversations menu, ⌘1–⌘9.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A full-width clickable row with a selected highlight (in the open
/// conversation's colour).
private struct SidebarRow<Content: View>: View {
    let isSelected: Bool
    var alignment: VerticalAlignment = .firstTextBaseline
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.conversationPalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(alignment: alignment, spacing: 10) { content() }
                // Rows size to their text; a thread bar then fills the height.
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? palette.soft : Color.clear)
                )
                .fontWeight(isSelected ? .semibold : .regular)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
    }
}

/// A message count; nothing at all when it's zero.
private struct CountText: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .labelFont(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
