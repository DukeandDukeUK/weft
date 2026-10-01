import SwiftUI

// MARK: - MessageListView

struct MessageListView: View {
    @Bindable var viewModel: WeftViewModel
    /// True while the view is scrolled to (or near) the newest message.
    /// New messages only auto-scroll in that case, like Messages.app.
    @State private var atBottom = true

    var body: some View {
        // Read the data HERE, in body, not inside ScrollViewReader's closure:
        // SwiftUI only redraws this view for changes to data read in body, so
        // reading it inside the closure meant new messages never appeared
        // until the selection changed.
        let visible = viewModel.visibleMessages
        let lastID = visible.last?.id
        let token = viewModel.scrollToken
        let jumpTarget = viewModel.jumpToMessageID
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, message in
                        if viewModel.isFirstOfDay(index, in: visible) {
                            DayDivider(date: message.date)
                        }
                        MessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding()
                // Fixed marker below the last message: scrolling to it always
                // lands at the true bottom, even before new rows are measured.
                Color.clear.frame(height: 1).id(Self.bottomID)
                }
            }
            // Open every thread at the newest message, and keep the view
            // pinned there as content grows.
            .defaultScrollAnchor(.bottom)
            // Track whether YOU scrolled away from the bottom. A new message
            // grows the content before we can scroll to it, which briefly looks
            // like "not at bottom" — so ignore changes caused by content growth.
            .onScrollGeometryChange(for: ScrollSpot.self) { geo in
                ScrollSpot(
                    bottomEdge: geo.contentOffset.y + geo.containerSize.height,
                    contentHeight: geo.contentSize.height
                )
            } action: { old, new in
                guard new.contentHeight == old.contentHeight else { return }
                atBottom = new.bottomEdge >= new.contentHeight - 80
            }
            .onAppear {
                scrollToBottom(proxy, lastID: lastID, animated: false)
                jumpIfNeeded(proxy)
            }
            // New message in this view: follow it if you were at the bottom.
            .onChange(of: lastID) { _, newLast in
                if atBottom { scrollToBottom(proxy, lastID: newLast, animated: true) }
            }
            // Sent a message / explicit request: always go to the bottom.
            .onChange(of: token) {
                scrollToBottom(proxy, lastID: lastID, animated: false)
            }
            .onChange(of: jumpTarget) { _, _ in jumpIfNeeded(proxy) }
        }
        // A fresh scroll view per thread, so each one opens at the bottom.
        .id(viewModel.sidebarSelection)
    }

    private static let bottomID = "bottom-marker"

    private func scrollToBottom(_ proxy: ScrollViewProxy, lastID: Int64?, animated: Bool) {
        guard lastID != nil else { return }
        atBottom = true
        // Scroll once layout has run, then again on the next pass: the first
        // jump uses estimated heights for rows that haven't been measured yet.
        DispatchQueue.main.async {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
            DispatchQueue.main.async {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    /// Search-result jumps set `jumpToMessageID` while this list may not be in
    /// the hierarchy yet (search results were showing), so handle both appear
    /// and change. Async dispatch lets layout settle before scrolling.
    private func jumpIfNeeded(_ proxy: ScrollViewProxy) {
        guard let target = viewModel.jumpToMessageID else { return }
        viewModel.jumpToMessageID = nil
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(target, anchor: .center) }
        }
    }
}

private struct ScrollSpot: Equatable {
    var bottomEdge: CGFloat
    var contentHeight: CGFloat
}

// MARK: - MessageRow

struct MessageRow: View {
    let message: ChatMessage

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 48) }
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 3) {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isFromMe ? Color.accentColor : Color.secondary.opacity(0.15))
                    .foregroundStyle(message.isFromMe ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                Text(Self.timeFormatter.string(from: message.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !message.isFromMe { Spacer(minLength: 48) }
        }
    }
}

// MARK: - DayDivider

struct DayDivider: View {
    let date: Date

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
            Text(Self.dayFormatter.string(from: date))
                .font(.caption)
                .foregroundStyle(.secondary)
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}
