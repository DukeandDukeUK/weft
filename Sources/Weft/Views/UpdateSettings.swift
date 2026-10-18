import Sparkle
import SwiftUI

// MARK: - Updates

/// The app's one Sparkle updater, so Settings can change its options.
@MainActor
enum Updates {
    static var updater: SPUUpdater?
}

/// Settings → Updates: always available, not only when an update is waiting
/// (Sparkle's own window only offers the "install automatically" choice then).
struct UpdateSettingsSection: View {
    @State private var checks = Updates.updater?.automaticallyChecksForUpdates ?? true
    @State private var installs = Updates.updater?.automaticallyDownloadsUpdates ?? false

    var body: some View {
        Section(String(localized: "Updates")) {
            Toggle(String(localized: "Check for updates automatically"), isOn: $checks)
                .onChange(of: checks) { _, on in Updates.updater?.automaticallyChecksForUpdates = on }
            Toggle(String(localized: "Download and install updates automatically"), isOn: $installs)
                .disabled(!checks)
                .onChange(of: installs) { _, on in Updates.updater?.automaticallyDownloadsUpdates = on }
            Text(installs && checks
                 ? String(localized: "Weft checks each time it opens. New versions download in the background and install when you quit Weft.")
                 : String(localized: "Weft checks each time it opens and asks before installing a new version."))
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
