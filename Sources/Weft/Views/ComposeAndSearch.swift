import SwiftUI

// MARK: - ComposeView

/// Reply box. Enter sends, Shift+Enter inserts a newline.
/// Sending goes out through the Messages app as you.
struct ComposeView: View {
    @Bindable var viewModel: WeftViewModel
    @State private var draft = ""

    private var draftIsBlank: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $draft)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(viewModel.selectedTopic.map { "Reply in “\($0.title)”" } ?? "Message")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 11)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                }
                .font(.body)
                .frame(minHeight: 36, maxHeight: 110)
                .fixedSize(horizontal: false, vertical: true)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    send()
                    return .handled
                }
            Button("Send") { send() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draftIsBlank || viewModel.isSending || !viewModel.canSend)
        }
        .padding()
        .help(viewModel.canSend
            ? "Enter to send, Shift+Enter for a new line (⌘+Enter also sends)"
            : "Sending needs a 1:1 conversation with a single participant")
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await viewModel.send(text) }
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
                            Text(message.isFromMe ? "You" : "Them")
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
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
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
