import SwiftUI

// MARK: - TokenUseSection

/// Settings → Token use: how many tokens Weft's AI calls have used.
struct TokenUseSection: View {
    @State private var log = TokenLog.shared
    @State private var confirmClear = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Section("AI usage") {
            row("Today", since: Calendar.current.startOfDay(for: Date()))
            row("Last 7 days", since: Date().addingTimeInterval(-7 * 86_400))
            row("Last 30 days", since: Date().addingTimeInterval(-30 * 86_400))
            row("All time", since: nil)

            DisclosureGroup("Recent calls") {
                if log.entries.isEmpty {
                    Text("No AI calls yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(log.entries.suffix(25).reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.purpose.label)
                                Spacer()
                                Text(entry.usage.map { Self.format($0.total) + " tokens" } ?? "count not available")
                                    .monospacedDigit()
                            }
                            Text("\(Self.timeFormatter.string(from: entry.date)) · \(entry.model)\(entry.usage.map { " · in \(Self.format($0.input)), cached \(Self.format($0.cachedInput)), out \(Self.format($0.output))" } ?? "")")
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Text("Counts come from the AI tool itself. Codex and Grok don't report them, so their calls are counted but show no tokens.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)

            Button("Clear token log…", role: .destructive) { confirmClear = true }
                .disabled(log.entries.isEmpty)
                .confirmationDialog("Clear the token log?", isPresented: $confirmClear) {
                    Button("Clear", role: .destructive) { log.clear() }
                }
        }
    }

    private func row(_ label: String, since: Date?) -> some View {
        let s = log.summary(since: since)
        return LabeledContent(label) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Self.format(s.usage.total)) tokens")
                    .monospacedDigit()
                Text("\(s.calls) call\(s.calls == 1 ? "" : "s") · in \(Self.format(s.usage.input)), cached \(Self.format(s.usage.cachedInput)), out \(Self.format(s.usage.output))\(s.unreported > 0 ? " · \(s.unreported) without counts" : "")")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func format(_ n: Int) -> String {
        n.formatted(.number)
    }
}
