import SwiftUI

/// Thread list. Rows are explicit buttons that set the selection directly,
/// rather than relying on List's own selection handling.
struct SidebarView: View {
    @Bindable var viewModel: WeftViewModel

    var body: some View {
        List {
            // Every added conversation, in your order (drag to reorder).
            // Right-click a conversation for more options.
            Section {
                ForEach(viewModel.followedChats) { chat in
                    // A tap, not a Button: a Button takes the mouse press,
                    // which stops the list from starting a drag to reorder.
                    ConversationRow(
                        isSelected: viewModel.settings.selectedChatRowID == chat.id,
                        action: { Task { await viewModel.selectChat(chat) } }
                    ) {
                        Label {
                            Text(ContactNames.shared.shortDisplay(chat.participants)).lineLimit(1)
                        } icon: {
                            Image(systemName: chat.participants.contains(",") ? "person.3.fill" : "person.crop.circle.fill")
                                .foregroundStyle(WeftStyle.accent)
                        }
                        Spacer(minLength: 4)
                        let count = viewModel.settings.selectedChatRowID == chat.id
                            ? viewModel.openUnread
                            : (viewModel.background.unreadCounts[chat.id] ?? 0)
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption2.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(WeftStyle.badge, in: Capsule())
                                .help("\(count) new message\(count == 1 ? "" : "s")")
                        }
                    }
                    .contextMenu {
                        Button("Open") { Task { await viewModel.selectChat(chat) } }
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
                HStack {
                    Text("Conversations")
                    Spacer()
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
                    SidebarRow(
                        isSelected: viewModel.sidebarSelection == .topic(topic.id),
                        action: { viewModel.openThread(topic.id) }
                    ) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(topic.title).lineLimit(1)
                                if !topic.summary.isEmpty {
                                    Text(topic.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        } icon: {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .foregroundStyle(WeftStyle.accent)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 3) {
                            if let date = viewModel.lastActivity(of: topic) {
                                Text(RelativeTime.short(date))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            CountText(count: topic.messageIds.count)
                        }
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Topics")
                    Spacer()
                    if let err = viewModel.historyError {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption2)
                        Text("Couldn't sort older messages").font(.caption2).foregroundStyle(.secondary)
                            .help(err)
                        Button("Retry") { viewModel.retryHistory() }
                            .buttonStyle(.link).font(.caption2)
                    } else if let p = viewModel.historyProgress, p.total > 0 {
                        ProgressView().controlSize(.mini)
                        Text("Sorting older messages… \(Int(Double(p.done) / Double(p.total) * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Follow-ups (\(viewModel.openLoopCount))") {
                let active = viewModel.loops.filter { $0.status == .open }
                let done = viewModel.loops.filter { $0.status != .open }
                if active.isEmpty {
                    Text(viewModel.loops.isEmpty ? "None found yet." : "Nothing outstanding.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(active) { loop in loopRow(loop) }
                if !done.isEmpty {
                    DisclosureGroup("Done (\(done.count))") {
                        ForEach(done) { loop in loopRow(loop) }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        // Wide enough that conversation names and thread titles fit.
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        .navigationTitle(viewModel.selectedChat.map { chatTitle($0) } ?? "Weft")
    }

    private func loopRow(_ loop: OpenLoop) -> some View {
        SidebarRow(
            isSelected: viewModel.sidebarSelection == .loop(loop.id),
            action: { viewModel.sidebarSelection = .loop(loop.id) }
        ) {
            Label {
                Text(loop.title).lineLimit(2)
            } icon: {
                Image(systemName: loop.status == .open ? "circle" : (loop.status == .resolved ? "checkmark.circle" : "xmark.circle"))
            }
            .foregroundStyle(loop.status == .open ? .primary : .secondary)
            .accessibilityLabel("\(loop.title), \(loop.status == .open ? "open" : (loop.status == .resolved ? "done" : "dismissed"))")
            Spacer()
        }
    }

    private func chatTitle(_ chat: ChatInfo) -> String {
        chat.participants.isEmpty ? "Conversation" : ContactNames.shared.display(chat.participants)
    }
}

/// Conversation row: same look as SidebarRow, but opened with a tap so the
/// list can drag it to reorder.
private struct ConversationRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline) { content() }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(WeftStyle.selection) : AnyShapeStyle(Color.clear))
            )
            .fontWeight(isSelected ? .semibold : .regular)
            .onTapGesture(perform: action)
            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
            // VoiceOver: one element, activates like a button. Keyboard:
            // Conversations menu, ⌘1–⌘9.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { action() }
    }
}

/// A full-width clickable row with a selected highlight.
private struct SidebarRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline) { content() }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(WeftStyle.selection) : AnyShapeStyle(Color.clear))
                )
                .fontWeight(isSelected ? .semibold : .regular)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
    }
}

private struct CountText: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}
