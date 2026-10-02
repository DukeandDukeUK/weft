import SwiftUI

struct ContentView: View {
    @State private var viewModel = WeftViewModel()

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
                } else {
                    Button {
                        Task { await viewModel.analyze() }
                    } label: {
                        Label("Re-sort everything", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(viewModel.messages.isEmpty)
                    .help("Not needed day to day — new messages are sorted automatically. This re-sorts the whole conversation from scratch.")
                }
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
        .task {
            await viewModel.startup()
        }
        .onReceive(NotificationCenter.default.publisher(for: .weftOpenSettings)) { _ in
            viewModel.showSettings = true
        }
    }
}

extension Notification.Name {
    /// Weft > Settings… — the window opens the settings sheet.
    static let weftOpenSettings = Notification.Name("weftOpenSettings")
}
