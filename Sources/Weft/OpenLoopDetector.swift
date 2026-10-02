import Foundation

// MARK: - OpenLoopDetector

/// Finds user requests with no confirmed resolution and assistant promises
/// with no confirmed completion, using the configured LLM.
struct OpenLoopDetector: Sendable {
    private struct LoopDTO: Decodable {
        let title: String
        let detail: String
        /// Transcript index of the message the loop comes from.
        let message: Int?
    }

    let client: LLMClient

    func detect(messages: [ChatMessage]) async throws -> [OpenLoop] {
        let (numbered, transcript) = TopicSegmenter.buildTranscript(messages: messages, maxTotalChars: client.transcriptCharLimit)
        let system = """
            You are reviewing a chat transcript between a person ("You") and one or more others (each line is labeled with who sent it; often an AI assistant).
            Find OPEN LOOPS:
            (a) requests or questions from You with no confirmed resolution later in the transcript;
            (b) promises, commitments, or "I'll follow up / I'll handle it" statements from the others with no confirmed completion.
            Ignore anything clearly finished. When unsure whether something resolved, include it.
            Return ONLY a JSON array — no markdown fences, no commentary — of objects with keys:
            "title": short title, 6 words max
            "detail": one or two sentences — what is pending and the last known state
            "message": the [index] of the message where it was asked or promised
            If there are no open loops, return [].
            """
        let raw = try await client.complete(systemPrompt: system, userPrompt: transcript, purpose: .openLoops)
        // An unreadable reply is an error, not "nothing outstanding".
        let cleaned = TopicSegmenter.stripFences(raw)
        guard let data = cleaned.data(using: .utf8),
              let dtos = try? JSONDecoder().decode([LoopDTO].self, from: data) else {
            throw TopicSegmenter.AnalysisError.badJSON(raw)
        }
        let now = Date()
        return dtos
            .map { dto in
                OpenLoop(
                    id: UUID(),
                    title: dto.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    detail: dto.detail.trimmingCharacters(in: .whitespacesAndNewlines),
                    status: .open,
                    createdDate: now,
                    sourceMessageId: dto.message.flatMap { numbered.indices.contains($0) ? numbered[$0].id : nil }
                )
            }
            .filter { !$0.title.isEmpty }
    }

    /// Which of these loops (raised earlier) does the later conversation
    /// clearly resolve? Returns their ids.
    func resolvedLater(loops: [OpenLoop], laterMessages: [ChatMessage]) async throws -> Set<UUID> {
        let (_, transcript) = TopicSegmenter.buildTranscript(messages: laterMessages, maxTotalChars: client.transcriptCharLimit)
        let list = loops.enumerated().map { "L\($0.offset): \($0.element.title) — \($0.element.detail)" }.joined(separator: "\n")
        let system = """
            Below are open items from earlier in a chat between a person ("You") and one or more others, followed by the later conversation.
            Decide which items the later conversation clearly shows were completed or settled.
            Return ONLY a JSON object — no markdown fences, no commentary: {"resolved": [numbers]} using the L-numbers. [] if none.
            When unsure, leave an item out.
            """
        let raw = try await client.complete(systemPrompt: system, userPrompt: "OPEN ITEMS:\n\(list)\n\nLATER CONVERSATION:\n\(transcript)", purpose: .openLoops)
        struct DTO: Decodable { let resolved: [Int] }
        guard let data = TopicSegmenter.stripFences(raw).data(using: .utf8),
              let dto = try? JSONDecoder().decode(DTO.self, from: data) else {
            throw TopicSegmenter.AnalysisError.badJSON(raw)
        }
        return Set(dto.resolved.compactMap { loops.indices.contains($0) ? loops[$0].id : nil })
    }
}
