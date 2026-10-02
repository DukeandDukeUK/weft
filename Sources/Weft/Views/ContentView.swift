import SwiftUI

struct ContentView: View {
    @State private var viewModel = WeftViewModel()
    @State private var confirmResort = false

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel)
        } detail: {
            DetailView(viewModel: viewModel)
        }
        .navigationTitle("Weft")
        .tint(WeftStyle.accent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if viewModel.isAnalyzing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .help("Sorting…")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                QueueButton(viewModel: viewModel)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Add Conversation…", systemImage: "plus") { viewModel.showChatPicker = true }
                    Divider()
                    Button("Re-sort Everything…", systemImage: "arrow.triangle.2.circlepath") { confirmResort = true }
                        .disabled(viewModel.messages.isEmpty || viewModel.isAnalyzing)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .searchable(text: $viewModel.searchText, placement: .toolbar, prompt: "Search conversation")
        .sheet(isPresented: $viewModel.showChatPicker) {
            ChatPickerView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .sheet(item: $viewModel.firstSortRequest) { chat in
            FirstSortView(viewModel: viewModel, chat: chat)
        }
        .confirmationDialog("Re-sort this whole conversation?", isPresented: $confirmResort) {
            Button("Re-sort Everything") { Task { await viewModel.analyze() } }
        } message: {
            Text("Not needed day to day — new messages are sorted automatically. This rebuilds every topic from scratch — replacing any renames, merges or moves you made — and uses more of your AI plan than normal sorting.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .weftSelectConversation)) { note in
            if let n = note.userInfo?["index"] as? Int, viewModel.followedChats.indices.contains(n) {
                Task { await viewModel.selectChat(viewModel.followedChats[n]) }
            }
        }
        .task {
            await viewModel.startup()
        }
        .onReceive(NotificationCenter.default.publisher(for: .weftOpenSettings)) { _ in
            viewModel.showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .weftOpenConversation)) { note in
            if let id = note.userInfo?["chat"] as? Int64 {
                let loop = (note.userInfo?["loop"] as? String).flatMap(UUID.init(uuidString:))
                Task { await viewModel.openConversation(id, loop: loop) }
            }
        }
        .sheet(isPresented: $viewModel.showNotificationSetup) {
            NotificationSetupView(settings: viewModel.settings) { viewModel.updateBadge() }
        }
    }
}

extension Notification.Name {
    /// Weft > Settings… — the window opens the settings sheet.
    static let weftOpenSettings = Notification.Name("weftOpenSettings")
}

extension Notification.Name {
    /// Conversations menu ⌘1–⌘9: open the Nth conversation.
    static let weftSelectConversation = Notification.Name("weftSelectConversation")
}

// MARK: - FirstSortView

/// Before a conversation is sent to an AI for the first time: say exactly
/// where it goes and how much of it.
struct FirstSortView: View {
    @Bindable var viewModel: WeftViewModel
    let chat: ChatInfo

    var body: some View {
        let settings = viewModel.settings
        let provider = settings.provider
        let local = provider?.isLocal ?? false
        let limit = provider?.transcriptCharLimit ?? 400_000
        let firstPart = TopicSegmenter.buildTranscript(messages: viewModel.messages, maxTotalChars: limit).messages.count
        let total = viewModel.messages.count
        VStack(alignment: .leading, spacing: 14) {
            Label(viewModel.topics.isEmpty ? "Sort this conversation?" : "Use this AI for this conversation?", systemImage: "square.stack.3d.up")
                .font(.title2.bold())
            Text(ContactNames.shared.display(chat.participants)).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("AI").foregroundStyle(.secondary)
                    Text(provider.map { "\($0.displayName) — \(settings.effectiveModel(for: $0).isEmpty ? "default model" : settings.effectiveModel(for: $0))" } ?? "None chosen")
                }
                GridRow {
                    Text("Goes to").foregroundStyle(.secondary)
                    Text(local ? "Nowhere — processed on this Mac" : (provider.map(Self.vendor) ?? "—"))
                }
                GridRow {
                    Text("How much").foregroundStyle(.secondary)
                    Text(!viewModel.topics.isEmpty
                         ? "New messages as they arrive" + (settings.sortOlderHistory ? ", plus any older history not yet sorted" : "")
                         : (firstPart >= total
                            ? "All \(total) messages"
                            : "The newest \(firstPart) of \(total) messages" + (settings.sortOlderHistory ? ", then the older ones in the background" : "")))
                }
            }
            Text("After this, only new messages are sent, a few at a time, as they arrive.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Choose a Different AI…") {
                    viewModel.postponeFirstSort()
                    viewModel.showSettings = true
                }
                Spacer()
                Button("Not Now") { viewModel.postponeFirstSort() }
                    .keyboardShortcut(.cancelAction)
                Button("Sort") { viewModel.approveFirstSort() }
                    .keyboardShortcut(.defaultAction)
                    .glassButton(prominent: true)
                    .disabled(provider == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }

    static func vendor(_ p: Provider) -> String {
        switch p {
        case .claude: return "Anthropic (Claude)"
        case .codex: return "OpenAI (ChatGPT)"
        case .gemini: return "Google (Gemini)"
        case .grok: return "xAI (Grok)"
        case .ollama, .lmstudio: return "this Mac"
        }
    }
}

// MARK: - QueueButton

/// Shows what Weft is working on (only when something is going on).
struct QueueButton: View {
    @Bindable var viewModel: WeftViewModel
    @State private var showing = false

    var body: some View {
        let items = viewModel.queue
        if !items.isEmpty {
            Button {
                showing.toggle()
            } label: {
                Label("Activity (\(items.count))", systemImage: "list.bullet.rectangle")
            }
            .help("What Weft is working on")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Activity").font(.headline)
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.symbol).foregroundStyle(WeftStyle.accent).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.conversation).font(.callout.weight(.medium))
                                Text(item.status).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Right-click a conversation to pause its sorting or skip older history.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(width: 300)
            }
        }
    }
}
