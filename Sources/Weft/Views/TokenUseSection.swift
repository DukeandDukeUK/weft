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
            row(String(localized: "Today"), since: Calendar.current.startOfDay(for: Date()))
            row(String(localized: "Last 7 days"), since: Date().addingTimeInterval(-7 * 86_400))
            row(String(localized: "Last 30 days"), since: Date().addingTimeInterval(-30 * 86_400))
            row(String(localized: "All time"), since: nil)

            DisclosureGroup("Recent calls") {
                if log.entries.isEmpty {
                    Text("No AI calls yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(log.entries.suffix(25).reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.purpose.label)
                                Spacer()
                                Text(entry.usage.map { String(localized: "\(Self.format($0.total)) tokens") } ?? String(localized: "count not available"))
                                    .monospacedDigit()
                            }
                            Text("\(Self.timeFormatter.string(from: entry.date)) · \(entry.model)\(entry.usage.map { Self.breakdown($0) } ?? "")")
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
                Text("^[\(s.calls) call](inflect: true)\(Self.breakdown(s.usage))\(s.unreported > 0 ? String(localized: " · \(s.unreported) without counts") : "")")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func format(_ n: Int) -> String {
        n.formatted(.number)
    }

    /// " · in 1,200, cached 800, out 90"
    private static func breakdown(_ usage: TokenUsage) -> String {
        String(localized: " · in \(format(usage.input)), cached \(format(usage.cachedInput)), out \(format(usage.output))",
               comment: "Token counts: input, cached input, output")
    }
}
