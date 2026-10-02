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

    private struct SegmentDTO: Decodable {
        let title: String
        let summary: String
        let start: Int
        let end: Int
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
            "start": index of the first message in the topic
            "end": index of the last message in the topic (inclusive)
            Rules:
            - Cover every message exactly once. Segments must be contiguous, non-overlapping, in order, from 0 to the last index.
            - Merge brief digressions into the surrounding topic. Make one topic per distinct subject; a long transcript can have dozens of topics.
            - If the whole transcript is one topic, return a single object.
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
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
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
        // Defensive: clamp indices, drop empties, sort by start.
        let valid = dtos
            .filter { $0.start >= 0 && $0.end >= $0.start && $0.start < messages.count }
            .map { dto -> (Int, Int, SegmentDTO) in
                (dto.start, min(dto.end, messages.count - 1), dto)
            }
            .sorted { $0.0 < $1.0 }
        guard !valid.isEmpty else { throw AnalysisError.noUsableSegments }
        return valid.map { start, end, dto in
            Topic(
                id: UUID(),
                title: dto.title.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: dto.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                messageIds: messages[start...end].map(\.id)
            )
        }
    }
}
