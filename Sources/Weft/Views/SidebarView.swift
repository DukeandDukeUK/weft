import SwiftUI

/// Thread list. Rows are explicit buttons that set the selection directly,
/// rather than relying on List's own selection handling.
struct SidebarView: View {
    @Bindable var viewModel: WeftViewModel

    var body: some View {
        List {
            Section("Threads") {
                SidebarRow(
                    isSelected: viewModel.sidebarSelection == .all || viewModel.sidebarSelection == nil,
                    action: { viewModel.sidebarSelection = .all }
                ) {
                    Label("All messages", systemImage: "tray.full")
                    Spacer()
                    CountText(count: viewModel.messages.count)
                }

                ForEach(viewModel.topics) { topic in
                    SidebarRow(
                        isSelected: viewModel.sidebarSelection == .topic(topic.id),
                        action: { viewModel.openThread(topic.id) }
                    ) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(topic.title).lineLimit(1)
                                if !topic.summary.isEmpty {
                                    Text(topic.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        } icon: {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .foregroundStyle(WeftStyle.accent)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 3) {
                            if let date = viewModel.lastActivity(of: topic) {
                                Text(RelativeTime.short(date))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            CountText(count: topic.messageIds.count)
                        }
                    }
                }
            }

            Section("Open loops (\(viewModel.openLoopCount))") {
                if viewModel.loops.isEmpty {
                    Text("None detected yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.loops) { loop in
                    SidebarRow(
                        isSelected: viewModel.sidebarSelection == .loop(loop.id),
                        action: { viewModel.sidebarSelection = .loop(loop.id) }
                    ) {
                        Label {
                            Text(loop.title).lineLimit(2)
                        } icon: {
                            Image(systemName: loop.status == .open ? "circle" : "checkmark.circle")
                        }
                        .foregroundStyle(loop.status == .open ? .primary : .secondary)
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(viewModel.selectedChat.map { chatTitle($0) } ?? "Weft")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.showChatPicker = true
                } label: {
                    Image(systemName: "plus.bubble")
                }
                .help("Choose a different conversation")
            }
        }
    }

    private func chatTitle(_ chat: ChatInfo) -> String {
        chat.participants.isEmpty ? "Conversation" : ContactNames.shared.display(chat.participants)
    }
}

/// A full-width clickable row with a selected highlight.
private struct SidebarRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline) { content() }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(WeftStyle.selection) : AnyShapeStyle(Color.clear))
                )
                .fontWeight(isSelected ? .semibold : .regular)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
    }
}

private struct CountText: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}
