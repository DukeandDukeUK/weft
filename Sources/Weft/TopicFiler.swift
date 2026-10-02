import Foundation

// MARK: - TopicFiler

/// Files NEW messages into the existing topics (or new ones) without
/// re-sorting the whole conversation. Also picks up new open loops and
/// existing loops the new messages resolve. One small call to the chosen AI.
struct TopicFiler: Sendable {
    struct Assignment: Sendable {
        var messageIds: [Int64]
        /// Index into the `topics` passed to `file`, or nil for a new topic.
        var topicIndex: Int?
        var newTitle: String
        var newSummary: String
        /// Replacement summary for an existing topic, when the outcome changed.
        var updatedSummary: String?
    }

    struct Result: Sendable {
        var assignments: [Assignment]
        var newLoops: [OpenLoop]
        /// Ids of the open loops (as passed in) these messages resolve.
        var resolvedLoopIDs: [UUID]
    }

    private struct AssignmentDTO: Decodable {
        let start: Int
        let end: Int
        let topic: Int?
        let newTitle: String?
        let newSummary: String?
        let summary: String?

        private enum CodingKeys: String, CodingKey {
            case start, end, topic, newTitle, newSummary, summary
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = try c.decode(Int.self, forKey: .start)
            end = try c.decode(Int.self, forKey: .end)
            // Models write the topic as 3 or as "T3"; accept both.
            if let n = try? c.decodeIfPresent(Int.self, forKey: .topic) {
                topic = n
            } else if let label = try? c.decodeIfPresent(String.self, forKey: .topic) {
                topic = Int(label.trimmingCharacters(in: CharacterSet(charactersIn: "Tt ")))
            } else {
                topic = nil
            }
            newTitle = try c.decodeIfPresent(String.self, forKey: .newTitle)
            newSummary = try c.decodeIfPresent(String.self, forKey: .newSummary)
            summary = try c.decodeIfPresent(String.self, forKey: .summary)
        }
    }

    private struct LoopDTO: Decodable {
        let title: String
        let detail: String
        /// Index of the NEW message the loop comes from.
        let message: Int?
        let owner: String?
        let due: String?
    }

    /// A resolved loop, written as 3, "L3", or (older replies) its title.
    private struct LoopRef: Decodable {
        let number: Int?
        let title: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self) {
                number = n; title = nil
            } else {
                let s = (try? c.decode(String.self)) ?? ""
                let digits = s.trimmingCharacters(in: CharacterSet(charactersIn: "Ll "))
                number = Int(digits)
                title = number == nil ? s : nil
            }
        }
    }

    private struct ResponseDTO: Decodable {
        let assignments: [AssignmentDTO]
        let newLoops: [LoopDTO]?
        let yourPromises: [PromiseDTO]?
        let resolvedLoops: [LoopRef]?
    }

    /// One per new message from You: what it promised, or null. Asking about
    /// each of your messages separately is what makes the AI notice casual
    /// promises ("I'll let you know…") instead of only the other side's.
    private struct PromiseDTO: Decodable {
        let message: Int?
        let promise: String?
        let due: String?
    }

    let client: LLMClient

    /// - Parameters:
    ///   - newMessages: the unfiled messages, oldest first.
    ///   - context: a few already-filed messages just before them, so short
    ///     replies ("yes, do that") land in the right topic.
    ///   - topics: candidate topics, most recently active first.
    ///   - openLoops: loops currently open.
    ///   - preferredTopic: index into `topics` of the thread you just replied
    ///     in; new messages most likely continue it.
    func file(
        newMessages: [ChatMessage],
        context: [(ChatMessage, String)],
        topics: [Topic],
        openLoops: [OpenLoop],
        preferredTopic: Int? = nil,
        purpose: CallPurpose = .filing
    ) async throws -> Result {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        func render(_ m: ChatMessage) -> String {
            var text = m.text.replacingOccurrences(of: "\n", with: " ")
            if text.count > 2_000 { text = String(text.prefix(2_000)) + "…" }
            return "\(m.speaker) (\(formatter.string(from: m.date))): \(text)"
        }

        var prompt = "EXISTING TOPICS (most recently active first):\n"
        for (i, t) in topics.enumerated() {
            prompt += "T\(i): \(t.title) — \(t.summary)\n"
        }
        if !context.isEmpty {
            prompt += "\nRECENT ALREADY-FILED MESSAGES (context only, do not file):\n"
            for (m, title) in context { prompt += "- [\(title)] \(render(m))\n" }
        }
        prompt += "\nOPEN LOOPS:\n"
        prompt += openLoops.isEmpty ? "(none)\n" : openLoops.enumerated().map { "L\($0.offset): \($0.element.title)" }.joined(separator: "\n") + "\n"
        if let p = preferredTopic, topics.indices.contains(p) {
            prompt += "\nThe person just replied in T\(p), so the new messages most likely continue it. File them in T\(p) unless a message clearly starts a different subject.\n"
        }
        prompt += "\nNEW MESSAGES TO FILE:\n"
        for (i, m) in newMessages.enumerated() { prompt += "[\(i)] \(render(m))\n" }

        let system = """
            You file new messages from a chat between a person ("You") and one or more others (each line is labeled with who sent it; often an AI assistant) into topics.
            Return ONLY a JSON object — no markdown fences, no commentary — with keys:
            "assignments": array covering every NEW message index exactly once, as contiguous in-order ranges:
               {"start": i, "end": j, "topic": k} (k as a plain number, e.g. 3 for T3) to add messages i..j to existing topic Tk, optionally with
               "summary": a new one-sentence summary for Tk if these messages change its outcome; or
               {"start": i, "end": j, "newTitle": "...", "newSummary": "..."} to start a new topic
               (title 6 words max, specific; summary one sentence).
            "newLoops": array of {"title", "detail", "message", "owner", "due"} for follow-ups raised in the NEW messages that
               aren't already in OPEN LOOPS: requests from You not yet answered or promises from the others not yet kept
               ("owner": "them"); requests from the others to You or promises You made, not yet done ("owner": "me").
               "message" is the index of the NEW message it comes from. "due": "YYYY-MM-DD" only if a date or deadline is
               stated (resolve words like "Friday" from the message dates), otherwise omit. [] if none.
            "yourPromises": one entry for EACH NEW message from You, in order: {"message": i, "promise": "short title"} if that
               message promises or commits You to something not yet done, even casually ("I'll let you know", "I'll send it"),
               otherwise {"message": i, "promise": null}. Add "due" as above if a date is stated. These are separate from
               "newLoops" (don't repeat them there).
            "resolvedLoops": array of OPEN LOOPS numbers (e.g. 2 for L2) that the NEW messages clearly resolve. [] if none.
            Use an existing topic when the new messages continue its subject; start a new topic only for a genuinely new subject.
            """
        let raw = try await client.complete(systemPrompt: system, userPrompt: prompt, purpose: purpose)
        return try Self.parse(raw, newMessages: newMessages, topics: topics, openLoops: openLoops)
    }

    /// Turn the AI's reply into assignments. Each new message gets exactly
    /// one thread: if the reply puts a message in two places, the first wins.
    static func parse(_ raw: String, newMessages: [ChatMessage], topics: [Topic], openLoops: [OpenLoop]) throws -> Result {
        let cleaned = TopicSegmenter.stripFences(raw)
        guard let data = cleaned.data(using: .utf8),
              let dto = try? JSONDecoder().decode(ResponseDTO.self, from: data) else {
            throw TopicSegmenter.AnalysisError.badJSON(raw)
        }

        var assignments: [Assignment] = []
        var claimed = Set<Int>()
        for a in dto.assignments.sorted(by: { $0.start < $1.start }) {
            let start = max(0, a.start)
            let end = min(a.end, newMessages.count - 1)
            guard start <= end else { continue }
            let validTopic = a.topic.flatMap { (0..<topics.count).contains($0) ? $0 : nil }
            let title = (a.newTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // A range with neither a valid topic nor a title is unusable —
            // check that BEFORE claiming its messages, so a bad assignment
            // can't block a good one for the same messages.
            guard validTopic != nil || !title.isEmpty else { continue }
            let indices = (start...end).filter { !claimed.contains($0) }
            guard !indices.isEmpty else { continue }
            claimed.formUnion(indices)
            assignments.append(Assignment(
                messageIds: indices.map { newMessages[$0].id },
                topicIndex: validTopic,
                newTitle: title,
                newSummary: (a.newSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                updatedSummary: a.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        let now = Date()
        var loops = (dto.newLoops ?? []).map {
            OpenLoop(
                id: UUID(),
                title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                detail: $0.detail.trimmingCharacters(in: .whitespacesAndNewlines),
                status: .open,
                createdDate: now,
                sourceMessageId: $0.message.flatMap { newMessages.indices.contains($0) ? newMessages[$0].id : nil },
                owner: LoopOwner.parse($0.owner),
                dueDate: DueDateParser.parse($0.due)
            )
        }.filter { !$0.title.isEmpty }
        var mine: [OpenLoop] = []
        for p in dto.yourPromises ?? [] {
            guard let i = p.message, newMessages.indices.contains(i), newMessages[i].isFromMe,
                  let title = p.promise?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { continue }
            let id = newMessages[i].id
            // Already listed (in newLoops or just above)? Once is enough.
            guard !(loops + mine).contains(where: { $0.sourceMessageId == id && $0.owner == .me }) else { continue }
            var text = newMessages[i].text.replacingOccurrences(of: "\n", with: " ")
            if text.count > 200 { text = String(text.prefix(200)) + "…" }
            mine.append(OpenLoop(id: UUID(), title: title, detail: "You said: \u{201C}\(text)\u{201D}", status: .open,
                                 createdDate: now, sourceMessageId: id, owner: .me, dueDate: DueDateParser.parse(p.due)))
        }
        loops += mine
        var resolved: [UUID] = []
        for ref in dto.resolvedLoops ?? [] {
            if let n = ref.number, openLoops.indices.contains(n) {
                resolved.append(openLoops[n].id)
            } else if let t = ref.title?.lowercased(),
                      let match = openLoops.first(where: { $0.title.lowercased() == t }) {
                resolved.append(match.id)
            }
        }
        return Result(assignments: assignments, newLoops: loops, resolvedLoopIDs: resolved)
    }
}

// MARK: - ChatDBWatcher

/// Fires `onChange` whenever Messages writes to its database. New messages
/// land in `chat.db-wal` first, so that's the file watched; SQLite deletes and
/// recreates it on checkpoints, so the watch re-arms itself.
final class ChatDBWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "weft.chatdb-watch")
    private var source: DispatchSourceFileSystemObject?
    private var stopped = false
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        queue.async { self.arm() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.source?.cancel()
            self.source = nil
        }
    }

    private func arm() {
        guard !stopped else { return }
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Messages/chat.db-wal")
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // WAL briefly absent (mid-checkpoint) — try again shortly.
            queue.asyncAfter(deadline: .now() + 1) { self.arm() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self, let current = self.source else { return }
            let events = current.data
            self.onChange()
            if events.contains(.delete) || events.contains(.rename) {
                current.cancel()
                self.source = nil
                self.queue.asyncAfter(deadline: .now() + 0.5) { self.arm() }
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }
}
