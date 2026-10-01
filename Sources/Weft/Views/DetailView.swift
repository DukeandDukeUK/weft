import SwiftUI

// MARK: - DetailView

/// Center pane: notice banner, then search results / loop detail / messages.
struct DetailView: View {
    @Bindable var viewModel: WeftViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let notice = viewModel.notice {
                NoticeBanner(text: notice) { viewModel.dismissNotice() }
            }

            if viewModel.dbMissing {
                MissingDBView(viewModel: viewModel)
            } else if !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SearchResultsView(viewModel: viewModel)
            } else if case .loop(let id)? = viewModel.sidebarSelection,
                      let loop = viewModel.loops.first(where: { $0.id == id }) {
                LoopDetailView(viewModel: viewModel, loop: loop)
            } else {
                if let topic = viewModel.selectedTopic {
                    ThreadHeader(topic: topic) { viewModel.sidebarSelection = .all }
                    Divider()
                }
                MessageListView(viewModel: viewModel)
                Divider()
                ComposeView(viewModel: viewModel)
            }

            if !viewModel.pendingMessageIDs.isEmpty,
               viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !viewModel.dbMissing {
                StaleBanner(count: viewModel.pendingMessageIDs.count, failed: viewModel.topicsStale) {
                    Task { await viewModel.analyze() }
                }
            }
        }
        .frame(minWidth: 420)
    }
}

// MARK: - NoticeBanner

struct NoticeBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: - StaleBanner

/// Shown while new messages are waiting to be filed into topics. Only offers
/// a button if automatic filing failed.
struct StaleBanner: View {
    let count: Int
    let failed: Bool
    let onReanalyze: () -> Void

    var body: some View {
        HStack {
            if failed {
                Image(systemName: "exclamationmark.triangle")
                Text("Couldn't sort \(count) new message\(count == 1 ? "" : "s") — will retry with the next message.")
                    .font(.callout)
                Spacer()
                Button("Sort now", action: onReanalyze)
            } else {
                ProgressView().scaleEffect(0.6)
                Text("Sorting \(count) new message\(count == 1 ? "" : "s") into topics…")
                    .font(.callout)
                Spacer()
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.08))
    }
}

// MARK: - MissingDBView

struct MissingDBView: View {
    @Bindable var viewModel: WeftViewModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "message.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No Messages database found")
                .font(.headline)
            Text("Weft reads your Messages history from ~/Library/Messages/chat.db. Make sure the Messages app is set up and signed in on this Mac (Messages > Settings > iMessage), then grant Full Disk Access in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Retry") {
                Task { await viewModel.startup() }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ThreadHeader

struct ThreadHeader: View {
    let topic: Topic
    let onAll: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title).font(.headline)
                if !topic.summary.isEmpty {
                    Text(topic.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("All messages", action: onAll)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
