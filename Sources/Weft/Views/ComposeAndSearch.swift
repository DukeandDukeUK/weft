import SwiftUI

// MARK: - ComposeView

/// Reply box. Enter sends, Shift+Enter inserts a newline.
/// Sending goes out through the Messages app as you.
struct ComposeView: View {
    @Bindable var viewModel: WeftViewModel

    private var draft: Binding<String> {
        Binding(get: { viewModel.currentDraft }, set: { viewModel.currentDraft = $0 })
    }

    private var draftIsBlank: Bool {
        viewModel.currentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Who a reply goes to — so it's never a surprise.
    private var recipientLine: String? {
        guard let chat = viewModel.selectedChat else { return nil }
        let names = ContactNames.shared.shortDisplay(chat.participants)
        if viewModel.isGroupChat {
            let count = chat.participants.split(separator: ",").count
            return "To the group: \(names) (\(count) people)"
        }
        return "To: \(ContactNames.shared.display(chat.participants))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let recipientLine {
                Text(recipientLine)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 16)
            }
            HStack(alignment: .center, spacing: 8) {
                // Grows up to 6 lines as you type; Enter sends, Option-Return
                // adds a new line (the standard Mac text-field behaviour).
                TextField(
                    viewModel.selectedTopic.map { "Reply in “\($0.title)”" }
                        ?? (viewModel.isGroupChat ? "Message the group" : "Message"),
                    text: draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .scaledFont(.body)
                .lineLimit(1...6)
                .onSubmit(send)
                .padding(.vertical, 8)
                .accessibilityLabel(recipientLine.map { "Message, \($0)" } ?? "Message")
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .scaledFont(.body, weight: .bold)
                        .frame(width: 18, height: 18)
                }
                .glassButton(prominent: true)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draftIsBlank || viewModel.isSending || !viewModel.canSend)
                .accessibilityLabel("Send")
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous), tint: WeftStyle.accent.opacity(0.08), interactive: true)
        }
        .help(viewModel.canSend
            ? "Enter to send, Option-Return for a new line"
            : "This conversation can't be replied to from Weft")
    }

    private func send() {
        let text = viewModel.currentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let chat = viewModel.settings.selectedChatRowID else { return }
        viewModel.currentDraft = ""
        Task {
            // Failed send: put the text back in that conversation's draft —
            // ahead of anything typed since — so nothing is lost.
            let sent = await viewModel.send(text)
            if !sent {
                let existing = viewModel.drafts[chat] ?? ""
                viewModel.drafts[chat] = existing.isEmpty ? text : text + "\n\n" + existing
            }
        }
    }
}

// MARK: - SearchResultsView

struct SearchResultsView: View {
    @Bindable var viewModel: WeftViewModel
    @State private var everywhere: [(chat: Int64, message: ChatMessage)] = []
    @State private var searching = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Search in", selection: $viewModel.searchAllConversations) {
                Text("This Conversation").tag(false)
                Text("All Conversations").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding(10)
            Divider()
            if viewModel.searchAllConversations {
                allResults
            } else {
                thisResults
            }
        }
        // Search every added conversation (debounced as you type).
        .task(id: "\(viewModel.searchText)|\(viewModel.searchAllConversations)") {
            guard viewModel.searchAllConversations else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            searching = true
            let found = (try? await ChatDBReader.shared.search(viewModel.searchText, inChats: viewModel.settings.followedChats)) ?? []
            everywhere = found.map { (chat: $0.chat, message: WeftViewModel.labeled($0.message)) }
            searching = false
        }
    }

    @ViewBuilder
    private var thisResults: some View {
        let results = viewModel.searchResults
        if results.isEmpty {
            empty
        } else {
            List(results) { message in
                Button { viewModel.jumpToMessage(message) } label: {
                    row(message, conversation: nil, topic: viewModel.topicTitle(for: message))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var allResults: some View {
        if everywhere.isEmpty {
            if searching { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) } else { empty }
        } else {
            List {
                ForEach(Array(everywhere.enumerated()), id: \.offset) { _, hit in
                    Button {
                        Task { await viewModel.jumpToMessage(hit.message, inChat: hit.chat) }
                    } label: {
                        row(hit.message, conversation: name(hit.chat), topic: nil)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var empty: some View {
        VStack {
            Spacer()
            Text("No matches for “\(viewModel.searchText)”").foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func name(_ chat: Int64) -> String {
        viewModel.chats.first { $0.id == chat }.map { ContactNames.shared.shortDisplay($0.participants) } ?? "Conversation"
    }

    private func row(_ message: ChatMessage, conversation: String?, topic: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let conversation {
                    Text(conversation).scaledFont(.caption).bold().foregroundStyle(WeftStyle.accent)
                }
                Text(message.speaker).scaledFont(.caption).bold().foregroundStyle(.secondary)
                Spacer()
                if let topic {
                    Text(topic).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text(message.text).lineLimit(3)
            HStack(spacing: 4) {
                Text(message.date, style: .date)
                Text(message.date, style: .time)
            }
            .scaledFont(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - LoopDetailView

struct LoopDetailView: View {
    @Bindable var viewModel: WeftViewModel
    let loop: OpenLoop

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    viewModel.sidebarSelection = .all
                } label: {
                    Label("Back to chat", systemImage: "chevron.left")
                }
                .glassButton()
                .keyboardShortcut(.escape, modifiers: [])
                Text(loop.title)
                    .scaledFont(.title2)
                    .bold()
                Text(loop.detail)
                    .scaledFont(.body)
                    .textSelection(.enabled)
                Text("Detected \(loop.createdDate, style: .date)")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                if let id = loop.sourceMessageId,
                   let message = viewModel.messages.first(where: { $0.id == id }) {
                    Button {
                        viewModel.jumpToMessage(message)
                    } label: {
                        Label("Show message", systemImage: "text.bubble")
                    }
                    .glassButton()
                }
                Picker("Status", selection: Binding(
                    get: { loop.status },
                    set: { viewModel.setLoopStatus(loop, $0) }
                )) {
                    ForEach(LoopStatus.allCases, id: \.self) { status in
                        Text(statusLabel(status)).tag(status)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)

                Divider().padding(.vertical, 4)

                Picker("Who", selection: Binding(
                    get: { loop.owner ?? .them },
                    set: { new in viewModel.updateLoop(loop.id) { $0.owner = new } }
                )) {
                    ForEach(LoopOwner.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)

                HStack {
                    Toggle("Due date", isOn: Binding(
                        get: { loop.dueDate != nil },
                        set: { on in
                            let tomorrow9 = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0,
                                of: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
                            viewModel.updateLoop(loop.id) { $0.dueDate = on ? tomorrow9 : nil }
                        }
                    ))
                    if let due = loop.dueDate {
                        DatePicker("", selection: Binding(
                            get: { due },
                            set: { new in viewModel.updateLoop(loop.id) { $0.dueDate = new } }
                        ))
                        .labelsHidden()
                    }
                }
                if loop.dueDate != nil || loop.snoozedUntil != nil {
                    Text("Weft reminds you with a notification at that time.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }

                if loop.status == .open {
                    Menu {
                        let cal = Calendar.current
                        Button("Later Today (3 hours)") { viewModel.snooze(loop, until: Date().addingTimeInterval(3 * 3600)) }
                        Button("Tomorrow Morning") {
                            viewModel.snooze(loop, until: cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: Date())!)!)
                        }
                        Button("Next Week") {
                            viewModel.snooze(loop, until: cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 7, to: Date())!)!)
                        }
                        if loop.isSnoozed() {
                            Divider()
                            Button("Unsnooze") { viewModel.updateLoop(loop.id) { $0.snoozedUntil = nil } }
                        }
                    } label: {
                        Label(loop.isSnoozed() ? "Snoozed until \(loop.snoozedUntil!.formatted(date: .abbreviated, time: .shortened))" : "Snooze", systemImage: "moon.zzz")
                    }
                    .fixedSize()
                }
            }
            .padding(24)
            .frame(maxWidth: 600, alignment: .leading)
            .glassSurface(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func statusLabel(_ status: LoopStatus) -> String {
        switch status {
        case .open: return "Open"
        case .resolved: return "Resolved"
        case .dismissed: return "Dismissed"
        }
    }
}
