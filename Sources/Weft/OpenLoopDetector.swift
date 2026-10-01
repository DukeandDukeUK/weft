import Foundation

// MARK: - OpenLoopDetector

/// Finds user requests with no confirmed resolution and assistant promises
/// with no confirmed completion, using the configured LLM.
struct OpenLoopDetector: Sendable {
    private struct LoopDTO: Decodable {
        let title: String
        let detail: String
    }

    let client: LLMClient

    func detect(messages: [ChatMessage]) async throws -> [OpenLoop] {
        let (_, transcript) = TopicSegmenter.buildTranscript(messages: messages, maxTotalChars: client.transcriptCharLimit)
        let system = """
            You are reviewing a chat transcript between a person ("You") and the other side ("Them" — often an AI assistant).
            Find OPEN LOOPS:
            (a) requests or questions from You with no confirmed resolution later in the transcript;
            (b) promises, commitments, or "I'll follow up / I'll handle it" statements from Them with no confirmed completion.
            Ignore anything clearly finished. When unsure whether something resolved, include it.
            Return ONLY a JSON array — no markdown fences, no commentary — of objects with keys:
            "title": short title, 6 words max
            "detail": one or two sentences — what is pending and the last known state
            If there are no open loops, return [].
            """
        let raw = try await client.complete(systemPrompt: system, userPrompt: transcript)
        let cleaned = TopicSegmenter.stripFences(raw)
        guard let data = cleaned.data(using: .utf8) else { return [] }
        let dtos = (try? JSONDecoder().decode([LoopDTO].self, from: data)) ?? []
        let now = Date()
        return dtos
            .map { dto in
                OpenLoop(
                    id: UUID(),
                    title: dto.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    detail: dto.detail.trimmingCharacters(in: .whitespacesAndNewlines),
                    status: .open,
                    createdDate: now
                )
            }
            .filter { !$0.title.isEmpty }
    }
}
