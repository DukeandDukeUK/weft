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

            if viewModel.needsFullDiskAccess {
                FullDiskAccessView(viewModel: viewModel)
            } else if viewModel.dbMissing {
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

// MARK: - FullDiskAccessView

/// First-launch screen: one click opens the exact Settings page, and Weft
/// carries on by itself once access is turned on.
struct FullDiskAccessView: View {
    @Bindable var viewModel: WeftViewModel
    @Environment(\.openURL) private var openURL
    @State private var openedSettings = false
    /// Backup "Quit & Reopen" link, shown only if Weft hasn't restarted by
    /// itself ~15 seconds after Settings was opened.
    @State private var showManualRestart = false

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Weft needs Full Disk Access")
                .font(.title2.bold())
            Text("Messages keeps its history in a protected folder. To read it, macOS needs you to turn on Full Disk Access for Weft. Weft only reads your messages — it never changes them.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Button {
                openURL(Self.settingsURL)
                openedSettings = true
                Task {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    showManualRestart = true
                }
            } label: {
                Label("Open Full Disk Access Settings", systemImage: "gearshape")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Text("Click the button, then turn on the switch next to **Weft**. Weft will reopen by itself.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Text("If Weft isn't in the list, click **+**, choose Weft in Applications, and click Open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            if openedSettings {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("Waiting for the switch…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if showManualRestart {
                Button("Switch is on but nothing happened? Quit & Reopen Weft") { viewModel.relaunch() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
