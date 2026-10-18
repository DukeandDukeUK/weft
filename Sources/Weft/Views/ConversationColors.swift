import SwiftUI

// MARK: - Conversation colours

/// Every conversation has a hue of its own. It tints the things that belong
/// to that conversation — its row and avatar in the sidebar, the topic
/// header, the canvas, the reply box and the other side's bubbles — so you
/// can tell at a glance whose conversation you're in. Your own bubbles stay
/// Weft indigo everywhere: indigo is "you", not a conversation.
///
/// The hue is picked automatically from the conversation's id, so it never
/// changes on its own; right-click a conversation to choose another. In a
/// group chat each person gets a hue of their own from the same set.
enum ConversationColors {
    struct Hue: Identifiable, Hashable {
        /// Position in `all`; what Settings stores for a chosen colour.
        let id: Int
        let name: String
        let degrees: Double
    }

    /// Eight hues spaced around the wheel, each readable as a light tint
    /// (light mode) and a deep tint (dark mode).
    static let all: [Hue] = [
        Hue(id: 0, name: String(localized: "Indigo", comment: "Conversation colour"), degrees: 232),
        Hue(id: 1, name: String(localized: "Amber", comment: "Conversation colour"), degrees: 28),
        Hue(id: 2, name: String(localized: "Rose", comment: "Conversation colour"), degrees: 340),
        Hue(id: 3, name: String(localized: "Green", comment: "Conversation colour"), degrees: 150),
        Hue(id: 4, name: String(localized: "Teal", comment: "Conversation colour"), degrees: 190),
        Hue(id: 5, name: String(localized: "Violet", comment: "Conversation colour"), degrees: 275),
        Hue(id: 6, name: String(localized: "Olive", comment: "Conversation colour"), degrees: 60),
        Hue(id: 7, name: String(localized: "Coral", comment: "Conversation colour"), degrees: 5),
    ]

    /// The hue a conversation gets unless you choose one: stable across
    /// launches, and neighbouring conversations get different ones.
    static func automaticIndex(forChat id: Int64) -> Int {
        Int(id.magnitude % UInt64(all.count))
    }

    /// The hue a person in a group chat gets, from their phone number or
    /// email. (Swift's own hashing changes every launch, so not that.)
    static func automaticIndex(forHandle handle: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in handle.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % UInt64(all.count))
    }

    @MainActor
    static func index(forChat id: Int64, settings: AppSettings = .shared) -> Int {
        settings.hueIndex(forChat: id) ?? automaticIndex(forChat: id)
    }

    @MainActor
    static func palette(forChat id: Int64, settings: AppSettings = .shared) -> ConversationPalette {
        palette(index: index(forChat: id, settings: settings))
    }

    static func palette(forHandle handle: String) -> ConversationPalette {
        palette(index: automaticIndex(forHandle: handle))
    }

    static func palette(index: Int) -> ConversationPalette {
        let hue = all[((index % all.count) + all.count) % all.count]
        let h = hue.degrees / 360
        return ConversationPalette(
            hueIndex: hue.id,
            // Accents: strong enough to read as a colour on both canvases.
            tint: Color(light: Color(hue: h, saturation: 0.62, brightness: 0.72),
                        dark: Color(hue: h, saturation: 0.45, brightness: 0.92)),
            // Their bubbles: a light wash with solid black text (light),
            // a deep tint with white text (dark) — the same contrast as
            // the plain grey they replace.
            theirBubble: Color(light: Color(hue: h, saturation: 0.20, brightness: 0.95),
                               dark: Color(hue: h, saturation: 0.30, brightness: 0.34)),
            // The conversation background: barely there, but there.
            canvas: Color(light: Color(hue: h, saturation: 0.05, brightness: 0.99),
                          dark: Color(hue: h, saturation: 0.28, brightness: 0.12))
        )
    }
}

/// The colours derived from one hue.
struct ConversationPalette: Equatable {
    let hueIndex: Int
    let tint: Color
    let theirBubble: Color
    let canvas: Color

    /// Sidebar selection and other soft highlights.
    var soft: Color { tint.opacity(0.18) }
}

private struct ConversationPaletteKey: EnvironmentKey {
    static let defaultValue = ConversationColors.palette(index: 0)
}

extension EnvironmentValues {
    /// The open conversation's colours.
    var conversationPalette: ConversationPalette {
        get { self[ConversationPaletteKey.self] }
        set { self[ConversationPaletteKey.self] = newValue }
    }
}
