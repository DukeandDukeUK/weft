import SwiftUI

// MARK: - Liquid Glass helpers

/// Weft's look: floating glass surfaces over the conversation (macOS 26+),
/// falling back to frosted material on macOS 15.
extension View {
    /// A floating glass panel in `shape`.
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        }
    }

    @available(macOS 26, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }

    /// macOS 26+ draws its own separator where a scroll view meets the
    /// toolbar area. Weft's header band has its own divider, and the system
    /// one landed partway down the conversation — so hide it.
    @ViewBuilder
    func hideSystemTopSeparator() -> some View {
        if #available(macOS 26, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }

    /// Round glass button (send, back, small actions).
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

// MARK: - Palette

enum WeftStyle {
    /// The icon's indigo — buttons, highlights, send.
    static let accent = Color(light: Color(red: 0.27, green: 0.31, blue: 0.86),
                              dark: Color(red: 0.52, green: 0.58, blue: 1.00))
    /// The icon's teal — secondary highlights.
    static let teal = Color(light: Color(red: 0.09, green: 0.62, blue: 0.66),
                            dark: Color(red: 0.30, green: 0.80, blue: 0.82))
    /// Your bubbles: the icon's indigo with white text.
    static let myBubble = Color(light: Color(red: 0.33, green: 0.42, blue: 0.95),
                                dark: Color(red: 0.26, green: 0.33, blue: 0.70))
    /// Their bubbles: plain cool gray, so they stand out from the indigo wash.
    static let theirBubble = Color(light: Color(red: 0.82, green: 0.83, blue: 0.87),
                                   dark: Color(red: 0.21, green: 0.22, blue: 0.29))
    /// Text in their bubbles: solid, for the most contrast on the gray.
    static let theirText = Color(light: .black, dark: .white)
    /// Conversation background: one flat, quiet indigo-white (light) / deep indigo (dark).
    static let canvasTop = Color(light: Color(red: 0.97, green: 0.97, blue: 0.99),
                                 dark: Color(red: 0.09, green: 0.09, blue: 0.17))
    static let canvasBottom = Color(light: Color(red: 0.97, green: 0.97, blue: 0.99),
                                    dark: Color(red: 0.09, green: 0.09, blue: 0.17))
    /// Sidebar selection.
    static let selection = LinearGradient(
        colors: [accent.opacity(0.24), teal.opacity(0.20)],
        startPoint: .leading, endPoint: .trailing
    )

    static let bubbleRadius: CGFloat = 18
    static let readableWidth: CGFloat = 760
}

extension Color {
    /// A color that follows light / dark appearance.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

/// "2m", "3h", "Yesterday", "Mon", "Sep 4" — for thread rows.
enum RelativeTime {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "\(Int(seconds / 3600))h" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if seconds < 6 * 86_400 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// The exact background macOS uses for the sidebar (follows light/dark).
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
