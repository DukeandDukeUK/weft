import SwiftUI

// MARK: - DetailView

/// Center pane: notice banner, then search results / loop detail / messages.
struct DetailView: View {
    @Bindable var viewModel: WeftViewModel

    private var isSearching: Bool {
        !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if viewModel.needsFullDiskAccess {
                FullDiskAccessView(viewModel: viewModel)
            } else if viewModel.dbMissing {
                MissingDBView(viewModel: viewModel)
            } else if isSearching {
                SearchResultsView(viewModel: viewModel)
            } else if case .loop(let id)? = viewModel.sidebarSelection,
                      let loop = viewModel.loops.first(where: { $0.id == id }) {
                LoopDetailView(viewModel: viewModel, loop: loop)
            } else {
                // Stacked, not layered: header row (with its divider right
                // under it), then the conversation, then the message box.
                // Layering the header over the scroll view made macOS draw
                // its own toolbar separator partway down the conversation.
                VStack(spacing: 0) {
                    if viewModel.selectedTopic != nil || viewModel.notice != nil || viewModel.betterLocalModel != nil {
                        VStack(spacing: 8) {
                            if let topic = viewModel.selectedTopic {
                                ThreadHeader(topic: topic) { viewModel.sidebarSelection = .all }
                            }
                            notices
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: WeftStyle.readableWidth)
                        .frame(maxWidth: .infinity)
                        // Same material as the threads sidebar, so the two match.
                        .background(SidebarMaterial().ignoresSafeArea(edges: .horizontal))
                        Divider()
                    }
                    MessageListView(viewModel: viewModel)
                    VStack(spacing: 8) {
                        if let chat = viewModel.settings.selectedChatRowID, viewModel.isPaused(chat) {
                            PausedBanner(count: viewModel.pendingMessageIDs.count) { viewModel.setPaused(chat, false) }
                        } else if !viewModel.pendingMessageIDs.isEmpty {
                            StaleBanner(count: viewModel.pendingMessageIDs.count, failed: viewModel.topicsStale) {
                                viewModel.retryFiling()
                            }
                        }
                        ComposeView(viewModel: viewModel)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                    .frame(maxWidth: WeftStyle.readableWidth)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [WeftStyle.canvasTop, WeftStyle.canvasBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    @ViewBuilder
    private var notices: some View {
        if let tier = viewModel.betterLocalModel {
            BetterModelBanner(viewModel: viewModel, tier: tier)
        }
        if let notice = viewModel.notice {
            let action = viewModel.noticeAction?.forText == notice ? viewModel.noticeAction : nil
            NoticeBanner(text: notice, actionLabel: action?.label, onAction: action.map { a in { a.run() } }) {
                viewModel.dismissNotice()
            }
        }
    }
}

// MARK: - NoticeBanner

struct NoticeBanner: View {
    let text: String
    var actionLabel: String? = nil
    var onAction: (() -> Void)? = nil
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(text)
                .scaledFont(.callout)
                .textSelection(.enabled)
            Spacer()
            if let actionLabel, let onAction {
                Button(actionLabel, action: onAction)
                    .glassButton()
                    .controlSize(.small)
            }
            Button { onDismiss() } label: {
                Image(systemName: "xmark").scaledFont(.caption, weight: .semibold)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous), tint: .orange.opacity(0.18))
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
        HStack(spacing: 8) {
            if failed {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Couldn't sort \(count) new message\(count == 1 ? "" : "s") — will retry with the next one.")
                    .scaledFont(.callout)
                Button("Retry", action: onReanalyze)
                    .glassButton()
                    .controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
                Text("Sorting \(count) new message\(count == 1 ? "" : "s") into topics…")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassSurface(Capsule(), tint: WeftStyle.teal.opacity(0.16))
    }
}

// MARK: - PausedBanner

struct PausedBanner: View {
    let count: Int
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle").foregroundStyle(.secondary)
            Text(count == 0 ? "Sorting is paused for this conversation." : "Sorting paused — \(count) new message\(count == 1 ? "" : "s") waiting.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
            Button("Resume", action: onResume)
                .glassButton()
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassSurface(Capsule())
    }
}

// MARK: - BetterModelBanner

/// "A better local model is available" — download with progress, or dismiss.
struct BetterModelBanner: View {
    @Bindable var viewModel: WeftViewModel
    let tier: Recommendations.LocalTier

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
            if viewModel.localPull.isRunning {
                ProgressView(value: viewModel.localPull.fraction) {
                    Text("Downloading \(tier.model)… \(viewModel.localPull.status)").scaledFont(.caption)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("A better local model is available for this Mac: **\(tier.model)** (about \(tier.size)).")
                        .scaledFont(.callout)
                    if let error = viewModel.localPull.error {
                        Text(error).scaledFont(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Download") { Task { await viewModel.installBetterLocalModel() } }
                    .glassButton(prominent: true)
                Button("Not now") { viewModel.dismissBetterLocalModel() }
                    .glassButton()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous), tint: WeftStyle.accent.opacity(0.12))
    }
}

// MARK: - FullDiskAccessView

/// First-launch screen: one click opens the exact Settings page; macOS then
/// offers "Quit & Reopen" itself when the switch is turned on.
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
                .scaledFont(.title2, weight: .bold)
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

            Text("Click the button, then turn on the switch next to **Weft**. When macOS asks, click **Quit & Reopen**.")
                .scaledFont(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Text("If Weft isn't in the list, click **+**, choose Weft in Applications, and click Open.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            if openedSettings {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("Waiting for you to turn on the switch…").scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            if showManualRestart {
                Button("Clicked “Later” on the macOS prompt? Quit & Reopen Weft") { viewModel.relaunch() }
                    .buttonStyle(.link)
                    .scaledFont(.caption)
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
                .scaledFont(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No Messages database found")
                .scaledFont(.headline)
            Text("Weft reads your Messages history from ~/Library/Messages/chat.db. Make sure the Messages app is set up and signed in on this Mac (Messages > Settings > iMessage), then grant Full Disk Access in Settings.")
                .scaledFont(.callout)
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
        HStack(alignment: .center, spacing: 12) {
            Button(action: onAll) {
                Image(systemName: "chevron.left").scaledFont(.body, weight: .semibold)
            }
            .glassButton()
            .buttonBorderShape(.circle)
            .keyboardShortcut(.escape, modifiers: [])
            .help("All messages (Esc)")
            .accessibilityLabel("Back to all messages")
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title).scaledFont(.headline)
                if !topic.summary.isEmpty {
                    Text(topic.summary)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(topic.summary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous), tint: WeftStyle.accent.opacity(0.12))
    }
}
