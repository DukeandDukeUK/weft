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
                        if !viewModel.pendingMessageIDs.isEmpty {
                            StaleBanner(count: viewModel.pendingMessageIDs.count, failed: viewModel.topicsStale) {
                                Task { await viewModel.analyze() }
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
            NoticeBanner(text: notice) { viewModel.dismissNotice() }
        }
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
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
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
                    .font(.callout)
                Button("Sort now", action: onReanalyze)
                    .glassButton()
                    .controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
                Text("Sorting \(count) new message\(count == 1 ? "" : "s") into threads…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassSurface(Capsule(), tint: WeftStyle.teal.opacity(0.16))
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
                    Text("Downloading \(tier.model)… \(viewModel.localPull.status)").font(.caption)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("A better local model is available for this Mac: **\(tier.model)** (about \(tier.size)).")
                        .font(.callout)
                    if let error = viewModel.localPull.error {
                        Text(error).font(.caption).foregroundStyle(.secondary)
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

            Text("Click the button, then turn on the switch next to **Weft**. When macOS asks, click **Quit & Reopen**.")
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
                    Text("Waiting for you to turn on the switch…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if showManualRestart {
                Button("Clicked “Later” on the macOS prompt? Quit & Reopen Weft") { viewModel.relaunch() }
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
        HStack(alignment: .center, spacing: 12) {
            Button(action: onAll) {
                Image(systemName: "chevron.left").font(.body.weight(.semibold))
            }
            .glassButton()
            .buttonBorderShape(.circle)
            .keyboardShortcut(.escape, modifiers: [])
            .help("All messages (Esc)")
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title).font(.headline)
                if !topic.summary.isEmpty {
                    Text(topic.summary)
                        .font(.caption)
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
