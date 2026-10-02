import Foundation

// MARK: - TopicEditor

/// Hand corrections to topics. Pure functions over the topic list, so the
/// view model can apply them with Undo and tests can check them directly.
/// Topics left with no messages are removed.
enum TopicEditor {
    static func rename(_ topics: [Topic], _ id: UUID, to title: String) -> [Topic] {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return topics }
        return topics.map { t in
            var t = t
            if t.id == id { t.title = clean }
            return t
        }
    }

    /// Everything in `source` joins `target`; `source` disappears.
    static func merge(_ topics: [Topic], _ source: UUID, into target: UUID) -> [Topic] {
        guard source != target,
              let from = topics.first(where: { $0.id == source }),
              topics.contains(where: { $0.id == target }) else { return topics }
        return topics.compactMap { t in
            if t.id == source { return nil }
            var t = t
            if t.id == target { t.messageIds = Array(Set(t.messageIds + from.messageIds)).sorted() }
            return t
        }
    }

    /// Move messages into an existing topic (taking them out of any other).
    static func move(_ topics: [Topic], messages ids: Set<Int64>, to target: UUID) -> [Topic] {
        guard topics.contains(where: { $0.id == target }), !ids.isEmpty else { return topics }
        return topics.compactMap { t in
            var t = t
            if t.id == target {
                t.messageIds = Array(Set(t.messageIds).union(ids)).sorted()
            } else {
                t.messageIds.removeAll { ids.contains($0) }
            }
            return t.messageIds.isEmpty ? nil : t
        }
    }

    /// Move messages into a brand-new topic.
    static func moveToNew(_ topics: [Topic], messages ids: Set<Int64>, title: String) -> (topics: [Topic], newID: UUID?) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ids.isEmpty, !clean.isEmpty else { return (topics, nil) }
        let new = Topic(id: UUID(), title: clean, summary: "", messageIds: ids.sorted())
        let rest: [Topic] = topics.compactMap { t in
            var t = t
            t.messageIds.removeAll { ids.contains($0) }
            return t.messageIds.isEmpty ? nil : t
        }
        return (rest + [new], new.id)
    }

    /// Where an AI assignment should go now. The topic it named may have
    /// been merged away while the AI was working: then use the topic that
    /// now holds its messages. Nil = it's gone entirely.
    static func currentIndex(of candidate: Topic, in topics: [Topic]) -> Int? {
        if let exact = topics.firstIndex(where: { $0.id == candidate.id }) { return exact }
        let ids = Set(candidate.messageIds)
        return topics.indices.max { a, b in
            topics[a].messageIds.filter(ids.contains).count < topics[b].messageIds.filter(ids.contains).count
        }.flatMap { topics[$0].messageIds.contains(where: ids.contains) ? $0 : nil }
    }

    /// A new topic's title: the AI's, or (redirect case) the old topic's —
    /// never empty.
    static func title(_ proposed: String, fallback: String) -> String {
        let t = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? (fallback.isEmpty ? "Untitled topic" : fallback) : t
    }

    /// Undo/Redo without losing later work: go back to `target`, but keep
    /// any message that was filed after the edit (present in `current`,
    /// absent from `applied`) in the topic it's in now.
    static func rebase(target: [Topic], applied: [Topic], current: [Topic]) -> [Topic] {
        let appliedIDs = Set(applied.flatMap(\.messageIds))
        let later = Set(current.flatMap(\.messageIds)).subtracting(appliedIDs)
        guard !later.isEmpty else { return target }
        var result = target.map { t -> Topic in
            var t = t
            t.messageIds.removeAll { later.contains($0) }
            return t
        }
        for t in current {
            let extra = t.messageIds.filter { later.contains($0) }
            guard !extra.isEmpty else { continue }
            if let i = result.firstIndex(where: { $0.id == t.id }) {
                result[i].messageIds = (result[i].messageIds + extra).sorted()
            } else {
                var kept = t
                kept.messageIds = extra
                result.append(kept)
            }
        }
        return result.filter { !$0.messageIds.isEmpty }
    }

    /// Split a topic: this message and everything after it (in that topic)
    /// become a new topic.
    static func split(_ topics: [Topic], _ id: UUID, from messageId: Int64, newTitle: String) -> (topics: [Topic], newID: UUID?) {
        guard let topic = topics.first(where: { $0.id == id }) else { return (topics, nil) }
        let moving = Set(topic.messageIds.filter { $0 >= messageId })
        // Splitting at the first message would just rename the topic.
        guard !moving.isEmpty, moving.count < topic.messageIds.count else { return (topics, nil) }
        return moveToNew(topics, messages: moving, title: newTitle)
    }
}
