import SwiftUI

// MARK: - NotificationOptions

/// The notification choices — used in Settings and in first-time setup.
struct NotificationOptions: View {
    @Bindable var settings: AppSettings
    @State private var testResult: String?

    var body: some View {
        Toggle("Show a banner when a new message arrives", isOn: $settings.notifyBanners)
        HStack {
            Picker("Sound", selection: $settings.notifySound) {
                Text("Default").tag("default")
                Text("None").tag("none")
                Divider()
                ForEach(Notifier.systemSounds, id: \.self) { Text($0).tag($0) }
            }
            .disabled(!settings.notifyBanners)
            Button {
                Notifier.preview(settings.notifySound)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help("Play this sound")
            .disabled(!settings.notifyBanners || settings.notifySound == "none")
        }
        Toggle("Show the number of new messages on Weft's Dock icon", isOn: $settings.dockBadge)
        HStack {
            Button("Send test notification") {
                Task { testResult = await Notifier.shared.sendTest(settings: settings) }
            }
            .disabled(!settings.notifyBanners)
            if let testResult {
                Text(testResult).font(.caption).foregroundStyle(.secondary)
            }
        }
        Text("Messages also shows its own banners. If you'd rather have only Weft's, turn off alerts for Messages in System Settings → Notifications → Messages.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - NotificationSetupView

/// First-time setup step, shown after picking the first conversation.
struct NotificationSetupView: View {
    @Bindable var settings: AppSettings
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Notifications", systemImage: "bell.badge")
                .font(.title2.bold())
            Text("Choose how Weft tells you about new messages. You can change this any time in Settings.")
                .foregroundStyle(.secondary)
            Form { NotificationOptions(settings: settings) }
                .formStyle(.grouped)
                .frame(minHeight: 260)
            HStack {
                Spacer()
                Button("Continue") {
                    settings.notificationsOnboarded = true
                    Task {
                        if settings.notifyBanners { _ = await Notifier.shared.requestPermission() }
                        onDone()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .glassButton(prominent: true)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }
}
