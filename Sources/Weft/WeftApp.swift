import SwiftUI
import Sparkle

@main
struct WeftApp: App {
    /// Sparkle: checks the appcast (SUFeedURL in Info.plist) for new
    /// versions, and offers to download and install them.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        // One window: every window would share the selected recipient, so a
        // second window could send to the wrong person.
        Window("Weft", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1050, height: 720)
        .commands {
            // Weft menu: About, Check for Updates…, ─, Settings… ⌘,, ─, …
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandMenu("Conversations") {
                ForEach(1...9, id: \.self) { n in
                    Button("Conversation \(n)") {
                        NotificationCenter.default.post(name: .weftSelectConversation, object: nil, userInfo: ["index": n - 1])
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Divider()
                Button("Settings…") {
                    NotificationCenter.default.post(name: .weftOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
                Divider()
            }
        }
    }
}

/// "Weft > Check for Updates…" (Sparkle's recommended SwiftUI setup).
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}
