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
                    .font(.caption)
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
                .font(.body)
                .lineLimit(1...6)
                .onSubmit(send)
                .padding(.vertical, 8)
                .accessibilityLabel(recipientLine.map { "Message, \($0)" } ?? "Message")
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
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

    var body: some View {
        let results = viewModel.searchResults
        if results.isEmpty {
            VStack {
                Spacer()
                Text("No matches for “\(viewModel.searchText)”")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(results) { message in
                Button {
                    viewModel.jumpToMessage(message)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(message.speaker)
                                .font(.caption)
                                .bold()
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let topic = viewModel.topicTitle(for: message) {
                                Text(topic)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Text(message.text)
                            .lineLimit(3)
                        HStack(spacing: 4) {
                            Text(message.date, style: .date)
                            Text(message.date, style: .time)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
        }
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
                    .font(.title2)
                    .bold()
                Text(loop.detail)
                    .font(.body)
                    .textSelection(.enabled)
                Text("Detected \(loop.createdDate, style: .date)")
                    .font(.caption)
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
