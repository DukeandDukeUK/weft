import SwiftUI

// MARK: - Text size

/// Weft's text size setting. Mac apps don't grow their text with a system
/// setting, so every piece of text asks for its size through `scaledFont`,
/// which multiplies the Mac's standard size by the chosen step.
enum TextScale {
    static let steps: [(scale: Double, label: String)] = [
        (0.85, "Small"), (1.0, "Default"), (1.15, "Large"), (1.3, "Extra Large"), (1.5, "Largest"),
    ]

    static func nearest(_ value: Double) -> Double {
        steps.min { abs($0.scale - value) < abs($1.scale - value) }!.scale
    }

    static func step(from value: Double, by delta: Int) -> Double {
        let i = steps.firstIndex { $0.scale == nearest(value) } ?? 1
        return steps[min(max(i + delta, 0), steps.count - 1)].scale
    }

    /// The Mac's standard point size for each text style.
    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline, .body: return 13
        case .callout: return 12
        case .subheadline: return 11
        case .footnote, .caption, .caption2: return 10
        @unknown default: return 13
        }
    }

    static func font(_ style: Font.TextStyle, weight: Font.Weight? = nil, scale: Double) -> Font {
        .system(size: baseSize(style) * scale, weight: weight ?? (style == .headline ? .bold : .regular))
    }
}

private struct ScaledFont: ViewModifier {
    let style: Font.TextStyle
    let weight: Font.Weight?
    func body(content: Content) -> some View {
        content.font(TextScale.font(style, weight: weight, scale: AppSettings.shared.textScale))
    }
}

extension View {
    /// A standard text style, at Weft's chosen text size.
    func scaledFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
        modifier(ScaledFont(style: style, weight: weight))
    }
}
