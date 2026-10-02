import SwiftUI

// MARK: - MessageListView

struct MessageListView: View {
    @Bindable var viewModel: WeftViewModel
    @Environment(\.undoManager) private var undoManager
    @State private var newTopicFor: Int64?
    @State private var newTopicName = ""
    /// True while the view is scrolled to (or near) the newest message.
    /// New messages only auto-scroll in that case, like Messages.app.
    @State private var atBottom = true

    var body: some View {
        // Read the data HERE, in body, not inside ScrollViewReader's closure:
        // SwiftUI only redraws this view for changes to data read in body, so
        // reading it inside the closure meant new messages never appeared
        // until the selection changed.
        let visible = viewModel.visibleMessages
        let lastID = visible.last?.id
        let token = viewModel.scrollToken
        let jumpTarget = viewModel.jumpToMessageID
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, message in
                        if viewModel.isFirstOfDay(index, in: visible) {
                            DayDivider(date: message.date)
                        }
                        MessageRow(
                            message: message,
                            senderLabel: viewModel.isGroupChat && !message.isFromMe
                                && (index == 0 || visible[index - 1].handleId != message.handleId
                                    || visible[index - 1].isFromMe)
                                ? message.senderName : nil
                        )
                        .id(message.id)
                        .contextMenu { messageMenu(message) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: WeftStyle.readableWidth)
                .frame(maxWidth: .infinity)
                // Fixed marker below the last message: scrolling to it always
                // lands at the true bottom, even before new rows are measured.
                Color.clear.frame(height: 1).id(Self.bottomID)
                }
            }
            // Open every thread at the newest message, and keep the view
            // pinned there as content grows.
            .defaultScrollAnchor(.bottom)
            .hideSystemTopSeparator()
            // Track whether YOU scrolled away from the bottom. A new message
            // grows the content before we can scroll to it, which briefly looks
            // like "not at bottom" — so ignore changes caused by content growth.
            .onScrollGeometryChange(for: ScrollSpot.self) { geo in
                ScrollSpot(
                    bottomEdge: geo.contentOffset.y + geo.containerSize.height,
                    contentHeight: geo.contentSize.height
                )
            } action: { old, new in
                guard new.contentHeight == old.contentHeight else { return }
                atBottom = new.bottomEdge >= new.contentHeight - 80
            }
            .onAppear {
                scrollToBottom(proxy, lastID: lastID, animated: false)
                jumpIfNeeded(proxy)
            }
            // New message in this view: follow it if you were at the bottom.
            .onChange(of: lastID) { _, newLast in
                if atBottom { scrollToBottom(proxy, lastID: newLast, animated: true) }
            }
            // Sent a message / explicit request: always go to the bottom.
            .onChange(of: token) {
                scrollToBottom(proxy, lastID: lastID, animated: false)
            }
            .onChange(of: jumpTarget) { _, _ in jumpIfNeeded(proxy) }
        }
        .alert("Move to New Topic", isPresented: Binding(get: { newTopicFor != nil }, set: { if !$0 { newTopicFor = nil } })) {
            TextField("Topic name", text: $newTopicName)
            Button("Move") {
                if let id = newTopicFor {
                    viewModel.editTopics("Move to New Topic", undoManager: undoManager) {
                        TopicEditor.moveToNew($0, messages: [id], title: newTopicName).topics
                    }
                }
                newTopicFor = nil
            }
            Button("Cancel", role: .cancel) { newTopicFor = nil }
        }
        // A fresh scroll view per thread, so each one opens at the bottom.
        .id(viewModel.sidebarSelection)
    }

    private static let bottomID = "bottom-marker"

    /// Right-click a message: move it, split the topic, copy, open in Messages.
    @ViewBuilder
    private func messageMenu(_ message: ChatMessage) -> some View {
        let current = viewModel.topics.first { $0.messageIds.contains(message.id) }
        Menu("Move to Topic") {
            ForEach(viewModel.topics.filter { $0.id != current?.id }) { topic in
                Button(topic.title) {
                    viewModel.editTopics("Move Message", undoManager: undoManager) {
                        TopicEditor.move($0, messages: [message.id], to: topic.id)
                    }
                }
            }
        }
        Button("Move to New Topic…") {
            newTopicName = ""
            newTopicFor = message.id
        }
        if let topic = viewModel.selectedTopic, topic.messageIds.first != message.id {
            Button("Split Topic Here") {
                viewModel.editTopics("Split Topic", undoManager: undoManager) {
                    TopicEditor.split($0, topic.id, from: message.id, newTitle: topic.title + " (continued)").topics
                }
            }
        }
        Divider()
        Button("Open in Messages") { viewModel.openInMessages() }
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.text, forType: .string)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, lastID: Int64?, animated: Bool) {
        guard lastID != nil else { return }
        atBottom = true
        // Scroll once layout has run, then again on the next pass: the first
        // jump uses estimated heights for rows that haven't been measured yet.
        DispatchQueue.main.async {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
            DispatchQueue.main.async {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    /// Search-result jumps set `jumpToMessageID` while this list may not be in
    /// the hierarchy yet (search results were showing), so handle both appear
    /// and change. Async dispatch lets layout settle before scrolling.
    private func jumpIfNeeded(_ proxy: ScrollViewProxy) {
        guard let target = viewModel.jumpToMessageID else { return }
        viewModel.jumpToMessageID = nil
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(target, anchor: .center) }
        }
    }
}

private struct ScrollSpot: Equatable {
    var bottomEdge: CGFloat
    var contentHeight: CGFloat
}

// MARK: - MessageRow

struct MessageRow: View {
    let message: ChatMessage
    /// Group chats: who sent it (shown when the sender changes).
    var senderLabel: String? = nil

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 48) }
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 3) {
                if let senderLabel, !senderLabel.isEmpty {
                    Text(senderLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }
                VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                    ForEach(message.attachments) { AttachmentView(attachment: $0) }
                    // A photo-only message has placeholder text, and a shared
                    // link's text is just the address its card shows: don't
                    // repeat them.
                    if (message.attachments.isEmpty || message.text != "[attachment]")
                        && !(message.link.map { LinkText.isJustTheLink(message.text, $0.url) } ?? false) {
                        Text(LinkText.attributed(message.text))
                            .textSelection(.enabled)
                            // Links in your (indigo) bubbles stay white, underlined.
                            .tint(message.isFromMe ? Color.white : WeftStyle.accent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(message.isFromMe ? WeftStyle.myBubble : WeftStyle.theirBubble,
                                        in: RoundedRectangle(cornerRadius: WeftStyle.bubbleRadius, style: .continuous))
                            // Solid black/white in their bubbles: macOS's normal text
                            // color is slightly see-through and loses contrast on gray.
                            .foregroundStyle(message.isFromMe ? Color.white : WeftStyle.theirText)
                    }
                    if let link = message.link { LinkPreviewCard(link: link) }
                }
                    // Reactions sit on the bubble's own top corner, like
                    // Messages (attached before the width limit, so they
                    // follow the bubble, not the column).
                    .overlay(alignment: message.isFromMe ? .topLeading : .topTrailing) {
                        if !message.reactions.isEmpty {
                            // Like Messages: the pill sits above the bubble,
                            // its bottom about halfway down the bubble's top
                            // padding, so it never covers the text.
                            ReactionBadge(reactions: message.reactions)
                                .offset(x: message.isFromMe ? -12 : 12, y: -16)
                        }
                    }
                    .padding(.top, message.reactions.isEmpty ? 0 : 16)
                    .frame(maxWidth: 560, alignment: message.isFromMe ? .trailing : .leading)
                Text(Self.timeFormatter.string(from: message.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !message.isFromMe { Spacer(minLength: 48) }
        }
    }
}

// MARK: - ReactionBadge

struct ReactionBadge: View {
    let reactions: [Reaction]
    @State private var showWho = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(reactions.enumerated()), id: \.offset) { _, reaction in
                Text(reaction.emoji).font(.system(size: 13))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .glassSurface(Capsule())
        .contentShape(Capsule())
        // Click to see who reacted, like Messages.
        .onTapGesture { showWho = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reactions: " + reactions.map { "\(Self.name(for: $0)) \($0.emoji)" }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showWho = true }
        .popover(isPresented: $showWho, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(reactions.enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 10) {
                        Avatar(handle: r.isFromMe ? nil : r.sender)
                        Text(Self.name(for: r)).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(r.emoji).font(.title3)
                    }
                }
            }
            .padding(12)
            .frame(minWidth: 200)
        }
        .help("Click to see who reacted")
    }

    static func name(for r: Reaction) -> String {
        if r.isFromMe { return "You" }
        return ContactNames.shared.name(for: r.sender) ?? (r.sender.isEmpty ? "Them" : r.sender)
    }
}

/// Contact photo, or initials in a tinted circle when there isn't one.
struct Avatar: View {
    /// nil = you.
    let handle: String?
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let handle, let data = ContactNames.shared.photo(for: handle), let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [WeftStyle.accent, WeftStyle.teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        guard let handle else { return "Me" }
        let name = ContactNames.shared.name(for: handle) ?? ""
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        if !letters.isEmpty { return String(letters).uppercased() }
        return handle.contains("@") ? String(handle.prefix(1)).uppercased() : "#"
    }
}

// MARK: - DayDivider

struct DayDivider: View {
    let date: Date

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        Text(Self.dayFormatter.string(from: date))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}
