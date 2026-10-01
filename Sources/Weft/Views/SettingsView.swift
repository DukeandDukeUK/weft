import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    @Bindable var viewModel: WeftViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var fdaOK: Bool?
    @State private var automationOK: Bool?

    var body: some View {
        Form {
            Section("Conversation") {
                LabeledContent("Conversation") {
                    Text(viewModel.settings.selectedHandleId.isEmpty
                        ? "None chosen"
                        : viewModel.settings.selectedHandleId)
                    .lineLimit(1)
                }
                Button("Choose conversation…") {
                    dismiss()
                    // Let the settings sheet finish dismissing before presenting the picker.
                    DispatchQueue.main.async { viewModel.showChatPicker = true }
                }
            }

            Section("Threads") {
                Toggle("Start thread replies with “Re: <thread> —”", isOn: Bindable(viewModel.settings).prefixThreadReplies)
                Text("The other side sees one long chat. The prefix tells it which subject your reply is about.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AISettingsSection(viewModel: viewModel)

            Section("Permissions") {
                permissionRow(
                    title: "Full Disk Access",
                    detail: "Needed to read ~/Library/Messages/chat.db",
                    ok: fdaOK,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                )
                permissionRow(
                    title: "Automation — Messages",
                    detail: "Needed to send replies from the app",
                    ok: automationOK,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
                Button("Check again", action: checkPermissions)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 460)
        .padding()
        .onAppear(perform: checkPermissions)
    }

    private func checkPermissions() {
        fdaOK = nil
        automationOK = nil
        Task {
            // Inherits MainActor from the view, so state assignment is safe.
            let fda = await ChatDBReader.shared.fullDiskAccessOK()
            let automation = MessageSender.automationAvailable()
            fdaOK = fda
            automationOK = automation
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, detail: String, ok: Bool?, settingsURL: String) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                statusDot(ok)
                Button("Open System Settings") {
                    if let url = URL(string: settingsURL) { openURL(url) }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func statusDot(_ ok: Bool?) -> some View {
        switch ok {
        case .none:
            ProgressView().scaleEffect(0.6)
        case .some(true):
            Circle().fill(.green).frame(width: 10, height: 10)
        case .some(false):
            Circle().fill(.red).frame(width: 10, height: 10)
        }
    }
}

// MARK: - ChatPickerView

struct ChatPickerView: View {
    @Bindable var viewModel: WeftViewModel
    @Environment(\.dismiss) private var dismiss

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose the conversation to sort")
                .font(.headline)
                .padding()
            if viewModel.chats.isEmpty {
                Text("No conversations found in the Messages database.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List(viewModel.chats) { chat in
                    Button {
                        Task { await viewModel.selectChat(chat) }
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            if chat.participants.isEmpty {
                                Text("(unknown participant)").lineLimit(1)
                            } else if ContactNames.shared.shortDisplay(chat.participants) != chat.participants {
                                // Known contact: name first, number after.
                                HStack(spacing: 6) {
                                    Text(ContactNames.shared.shortDisplay(chat.participants)).bold().lineLimit(1)
                                    Text(chat.participants).foregroundStyle(.secondary).lineLimit(1)
                                }
                            } else {
                                Text(chat.participants).lineLimit(1)
                            }
                            HStack(spacing: 4) {
                                Text("\(chat.messageCount) messages")
                                if let date = chat.lastDate {
                                    Text("·")
                                    Text(Self.dateFormatter.string(from: date))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if let snippet = chat.lastSnippet, !snippet.isEmpty {
                                Text(snippet)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .task { await ContactNames.shared.load() }
    }
}
