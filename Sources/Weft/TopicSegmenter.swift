import Foundation

// MARK: - TopicSegmenter

/// Splits the transcript into labeled topics using the configured LLM.
struct TopicSegmenter: Sendable {
    enum AnalysisError: Error, LocalizedError {
        case badJSON(String)
        case noUsableSegments

        var errorDescription: String? {
            switch self {
            case .badJSON(let raw):
                return "The model did not return valid topic JSON. Raw output (truncated): \(raw.prefix(300))"
            case .noUsableSegments:
                return "The model returned no usable topic segments."
            }
        }
    }

    /// One topic: either a single start/end, or several "ranges" when the
    /// conversation returns to the same subject later (A, B, then A again).
    private struct SegmentDTO: Decodable {
        let title: String
        let summary: String
        let start: Int?
        let end: Int?
        let ranges: [[Int]]?

        var spans: [(Int, Int)] {
            if let ranges, !ranges.isEmpty {
                return ranges.compactMap { r in r.count >= 2 ? (r[0], r[1]) : (r.count == 1 ? (r[0], r[0]) : nil) }
            }
            if let start, let end { return [(start, end)] }
            return []
        }
    }

    let client: LLMClient

    func segment(messages: [ChatMessage]) async throws -> [Topic] {
        let (numbered, transcript) = Self.buildTranscript(messages: messages, maxTotalChars: client.transcriptCharLimit)
        let system = """
            You are organizing a chat transcript between a person ("You") and one or more others (each line is labeled with who sent it; often an AI assistant) into topics.
            Messages are numbered [0], [1], ... in chronological order.
            Return ONLY a JSON array — no markdown fences, no commentary — of objects with keys:
            "title": short topic title, 6 words max, specific ("Bali visa paperwork", not "Discussion")
            "summary": one sentence on what happened and/or the outcome
            "ranges": array of [start, end] index pairs (inclusive) — the stretches of the conversation that belong to this topic
            Rules:
            - Cover every message exactly once; ranges never overlap.
            - When the conversation comes back to an earlier subject, add another range to that SAME topic instead of creating a second topic with the same subject.
            - Merge brief digressions into the surrounding topic. Make one topic per distinct subject; a long transcript can have dozens of topics.
            - If the whole transcript is one topic, return a single object with one range.
            """
        let raw = try await client.complete(systemPrompt: system, userPrompt: transcript, purpose: .fullSort)
        return try Self.parseTopics(from: raw, messages: numbered)
    }

    // MARK: - Transcript building (pure; unit-testable)

    /// Numbers the most recent messages and renders them as text. Caps are
    /// sized for Claude; when the chat is over the cap, the OLDEST messages
    /// are dropped so the newest are always included.
    static func buildTranscript(
        messages: [ChatMessage],
        maxMessages: Int = 5_000,
        maxCharsPerMessage: Int = 2_000,
        maxTotalChars: Int = 400_000
    ) -> (messages: [ChatMessage], text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        func body(_ message: ChatMessage) -> String {
            var text = message.text.replacingOccurrences(of: "\n", with: " ")
            if text.count > maxCharsPerMessage {
                text = String(text.prefix(maxCharsPerMessage)) + "…"
            }
            let speaker = message.speaker
            return "\(speaker) (\(formatter.string(from: message.date))): \(text)"
        }
        // Walk newest → oldest until a cap is hit.
        var kept: [(ChatMessage, String)] = []
        var total = 0
        for message in messages.reversed() {
            guard kept.count < maxMessages else { break }
            let line = body(message)
            total += line.count + 10 // room for the "[index] " prefix
            if total > maxTotalChars { break }
            kept.append((message, line))
        }
        kept.reverse()
        let lines = kept.enumerated().map { index, pair in "[\(index)] \(pair.1)" }
        return (kept.map(\.0), lines.joined(separator: "\n"))
    }

    /// Strip ```json ... ``` fences some models add despite instructions.
    /// Visible for unit testing.
    static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let firstNewline = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNewline)...])
            } else {
                t = ""
            }
            if let fenceRange = t.range(of: "```", options: .backwards) {
                t = String(t[..<fenceRange.lowerBound])
            }
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep just the first complete JSON object/array: some models add
        // text before it or a stray tag after it (e.g. "</final>").
        return firstJSONValue(in: t) ?? t
    }

    /// The first balanced {...} or [...] in `s`, ignoring brackets inside
    /// strings. Nil if there isn't one.
    static func firstJSONValue(in s: String) -> String? {
        guard let start = s.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "{", "[": depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 0 { return String(s[start...i]) }
                default: break
                }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Parse and validate the model's segment list against the messages.
    /// Visible for unit testing.
    static func parseTopics(from raw: String, messages: [ChatMessage]) throws -> [Topic] {
        let cleaned = stripFences(raw)
        guard let data = cleaned.data(using: .utf8) else { throw AnalysisError.badJSON(raw) }
        let dtos: [SegmentDTO]
        do {
            dtos = try JSONDecoder().decode([SegmentDTO].self, from: data)
        } catch {
            throw AnalysisError.badJSON(raw)
        }
        let count = messages.count
        // Which topic each message index belongs to (first claim wins).
        var owner = [Int?](repeating: nil, count: count)
        var titles: [String] = []
        var summaries: [String] = []
        var byTitle: [String: Int] = [:]
        for dto in dtos {
            let title = dto.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = title.lowercased()
            // Same subject returned twice as separate topics: merge them.
            let topicIndex: Int
            if let existing = byTitle[key] {
                topicIndex = existing
            } else {
                topicIndex = titles.count
                titles.append(title)
                summaries.append(dto.summary.trimmingCharacters(in: .whitespacesAndNewlines))
                byTitle[key] = topicIndex
            }
            for (a, b) in dto.spans where a >= 0 && b >= a && a < count {
                for i in a...min(b, count - 1) where owner[i] == nil { owner[i] = topicIndex }
            }
        }
        guard owner.contains(where: { $0 != nil }) else { throw AnalysisError.noUsableSegments }
        // Messages the model skipped join the topic of the message before
        // them (or after, at the very start).
        var last: Int? = owner.first(where: { $0 != nil }) ?? nil
        for i in 0..<count {
            if let o = owner[i] { last = o } else { owner[i] = last }
        }
        var ids = [[Int64]](repeating: [], count: titles.count)
        for i in 0..<count { if let o = owner[i] { ids[o].append(messages[i].id) } }
        return titles.indices.compactMap { t in
            ids[t].isEmpty ? nil : Topic(id: UUID(), title: titles[t], summary: summaries[t], messageIds: ids[t])
        }
    }
}
