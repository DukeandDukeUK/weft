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
                                ? message.senderName : nil,
                            palette: viewModel.palette(for: message),
                            menuItems: { menuItems(for: message) }
                        )
                        .id(message.id)
                        .contextMenu { MessageMenuContent(items: menuItems(for: message)) }
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
        // A fresh scroll view per thread AND per loaded conversation, so each
        // one opens at the bottom with its messages already in place. Jumping
        // to the bottom after a long conversation's messages arrive in an
        // existing view used estimated row heights and could land on an empty
        // stretch (blank until something new was sent). New messages are
        // added at the end, so the oldest one only changes when a different
        // set of messages is loaded.
        .id(ListIdentity(selection: viewModel.sidebarSelection, oldest: viewModel.visibleMessages.first?.id))
    }

    private static let bottomID = "bottom-marker"

    /// Right-click a message: move it, split the topic, copy, open in Messages.
    private func menuItems(for message: ChatMessage) -> [MessageMenuItem] {
        let current = viewModel.topics.first { $0.messageIds.contains(message.id) }
        var items: [MessageMenuItem] = [
            MessageMenuItem(title: String(localized: "Move to Topic"), children: viewModel.topics.filter { $0.id != current?.id }.map { topic in
                MessageMenuItem(title: topic.title) {
                    viewModel.editTopics(String(localized: "Move Message", comment: "Undo menu"), undoManager: undoManager) {
                        TopicEditor.move($0, messages: [message.id], to: topic.id)
                    }
                }
            }),
            MessageMenuItem(title: String(localized: "Move to New Topic…")) {
                newTopicName = ""
                newTopicFor = message.id
            },
        ]
        if let topic = viewModel.selectedTopic, topic.messageIds.first != message.id {
            items.append(MessageMenuItem(title: String(localized: "Split Topic Here")) {
                viewModel.editTopics(String(localized: "Split Topic", comment: "Undo menu"), undoManager: undoManager) {
                    TopicEditor.split($0, topic.id, from: message.id, newTitle: String(localized: "\(topic.title) (continued)", comment: "Title of the second half of a split topic")).topics
                }
            })
        }
        items += [
            .divider,
            MessageMenuItem(title: String(localized: "Open in Messages")) { viewModel.openInMessages() },
            MessageMenuItem(title: String(localized: "Copy Whole Message")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            },
        ]
        return items
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, lastID: Int64?, animated: Bool) {
        guard lastID != nil else { return }
        atBottom = true
        // First jump to the newest MESSAGE: the list builds the row it's asked
        // for, so this lands on real content even when the rows above it
        // haven't been measured yet. (Jumping straight to the marker below
        // the list used estimated heights and could land on an empty stretch,
        // so a long conversation opened blank.) Then, with the bottom rows
        // built, settle on the marker so the padding below shows too.
        DispatchQueue.main.async {
            proxy.scrollTo(lastID, anchor: .bottom)
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

private struct ListIdentity: Hashable {
    let selection: SidebarSelection?
    let oldest: Int64?
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
    /// The conversation's colours (or, in a group, this person's).
    var palette: ConversationPalette = ConversationColors.palette(index: 0)
    /// Right-click menu, also shown when right-clicking the selectable text.
    var menuItems: () -> [MessageMenuItem] = { [] }

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
                        .scaledFont(.caption, weight: .semibold)
                        .foregroundStyle(palette.tint)
                        .padding(.leading, 12)
                }
                VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                    ForEach(message.attachments) { AttachmentView(attachment: $0) }
                    // A photo-only message has placeholder text, and a shared
                    // link's text is just the address its card shows: don't
                    // repeat them.
                    if (message.attachments.isEmpty || message.text != "[attachment]")
                        && !(message.link.map { LinkText.isJustTheLink(message.text, $0.url) } ?? false) {
                        // Selectable (drag to pick part of it), with Weft's menu
                        // on right-click. Solid black/white in their bubbles:
                        // macOS's normal text color is slightly see-through and
                        // loses contrast on gray.
                        SelectableText(
                            text: LinkText.attributed(message.text),
                            color: message.isFromMe ? .white : NSColor(WeftStyle.theirText),
                            fontSize: TextScale.baseSize(.body) * AppSettings.shared.textScale,
                            menuItems: menuItems
                        )
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(message.isFromMe ? WeftStyle.myBubble : palette.theirBubble,
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
                    .scaledFont(.caption2)
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
                Text(reaction.emoji).scaledFont(.body)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .glassSurface(Capsule())
        .contentShape(Capsule())
        // Click to see who reacted, like Messages.
        .onTapGesture { showWho = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Reactions: \(reactions.map { "\(Self.name(for: $0)) \($0.emoji)" }.joined(separator: ", "))"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showWho = true }
        .popover(isPresented: $showWho, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(reactions.enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 10) {
                        Avatar(handle: r.isFromMe ? nil : r.sender)
                        Text(Self.name(for: r)).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(r.emoji).scaledFont(.title3)
                    }
                }
            }
            .padding(12)
            .frame(minWidth: 200)
        }
        .help("Click to see who reacted")
    }

    static func name(for r: Reaction) -> String {
        if r.isFromMe { return String(localized: "You", comment: "The person using Weft") }
        return ContactNames.shared.name(for: r.sender) ?? (r.sender.isEmpty ? String(localized: "Them", comment: "The other side of a conversation") : r.sender)
    }
}

/// Contact photo, or initials in a tinted circle when there isn't one.
struct Avatar: View {
    /// nil = you.
    let handle: String?
    var size: CGFloat = 28
    /// Colour behind the initials; nil = Weft's own.
    var tint: Color? = nil

    var body: some View {
        Group {
            if let handle, let data = ContactNames.shared.photo(for: handle), let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: tint.map { [$0, $0.opacity(0.75)] } ?? [WeftStyle.accent, WeftStyle.teal],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        guard let handle else { return String(localized: "Me", comment: "Initials shown for the person using Weft") }
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
            .scaledFont(.caption, weight: .medium)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}
