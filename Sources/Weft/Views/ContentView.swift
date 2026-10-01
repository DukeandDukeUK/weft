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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if viewModel.isAnalyzing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .help("Sorting…")
                } else {
                    Button("Re-sort everything") {
                        Task { await viewModel.analyze() }
                    }
                    .disabled(viewModel.messages.isEmpty)
                    .help("Not needed day to day — new messages are sorted automatically. This re-sorts the whole conversation from scratch.")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
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
    }
}
