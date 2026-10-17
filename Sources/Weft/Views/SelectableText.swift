import AppKit
import SwiftUI

// MARK: - Message menu items

/// One item in a message's right-click menu. Built once and shown both by
/// SwiftUI (around the bubble) and by the selectable text inside it, so the
/// menu is the same wherever you click.
struct MessageMenuItem: Identifiable {
    let id = UUID()
    var title: String
    var action: (() -> Void)? = nil
    var children: [MessageMenuItem] = []
    var isDivider = false

    static let divider = MessageMenuItem(title: "", isDivider: true)
}

/// SwiftUI version of the menu.
struct MessageMenuContent: View {
    let items: [MessageMenuItem]
    var body: some View {
        ForEach(items) { item in
            if item.isDivider {
                Divider()
            } else if !item.children.isEmpty {
                Menu(item.title) {
                    ForEach(item.children) { child in Button(child.title) { child.action?() } }
                }
            } else {
                Button(item.title) { item.action?() }
            }
        }
    }
}

// MARK: - SelectableText

/// Message text you can select part of (drag across it, then ⌘C or
/// right-click → Copy), like in Messages. Links still open with a click.
/// Right-clicking shows Weft's menu (Move to Topic…) above Copy and Look Up.
struct SelectableText: NSViewRepresentable {
    let text: AttributedString
    let color: NSColor
    let fontSize: CGFloat
    let menuItems: () -> [MessageMenuItem]

    func makeNSView(context: Context) -> MessageTextView {
        // TextKit 1, the same text system `measure` uses.
        let view = MessageTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateNSView(_ view: MessageTextView, context: Context) {
        let content = attributed()
        if view.textStorage?.isEqual(to: content) != true {
            view.textStorage?.setAttributedString(content)
        }
        view.linkTextAttributes = [
            .foregroundColor: color,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        view.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        view.menuItems = menuItems
    }

    /// As wide as the text needs (up to the space offered), as tall as it wraps to.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MessageTextView, context: Context) -> CGSize? {
        let content = attributed()
        let maxWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 10_000
        let natural = Self.measure(content, width: 10_000).width
        let width = ceil(min(natural + 1, maxWidth))
        let height = ceil(Self.measure(content, width: width).height)
        return CGSize(width: max(width, 1), height: max(height, ceil(fontSize * 1.2)))
    }

    /// Lays the text out exactly as the text view will (same text system,
    /// no padding), so wrapping and height match what's drawn.
    static func measure(_ content: NSAttributedString, width: CGFloat) -> CGSize {
        let storage = NSTextStorage(attributedString: content)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return layout.usedRect(for: container).size
    }

    private func attributed() -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: NSAttributedString(text))
        let all = NSRange(location: 0, length: result.length)
        result.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize), range: all)
        result.addAttribute(.foregroundColor, value: color, range: all)
        return result
    }
}

final class MessageTextView: NSTextView {
    var menuItems: () -> [MessageMenuItem] = { [] }

    /// Weft's items first, then the text items that make sense for a
    /// message you can't edit (Copy, Look Up, Translate, Search, Share).
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for item in menuItems() { menu.addItem(Self.nsItem(item)) }
        let keep = ["Look Up", "Translate", "Search With", "Share"]
        let system = super.menu(for: event)?.items.filter { item in
            item.action == #selector(NSText.copy(_:)) || keep.contains { item.title.hasPrefix($0) }
        } ?? []
        if !system.isEmpty {
            menu.addItem(.separator())
            for item in system {
                item.menu?.removeItem(item)
                menu.addItem(item)
            }
        }
        return menu
    }

    private static func nsItem(_ item: MessageMenuItem) -> NSMenuItem {
        if item.isDivider { return .separator() }
        let ns = ClosureMenuItem(title: item.title, handler: item.action)
        if !item.children.isEmpty {
            let sub = NSMenu(title: item.title)
            for child in item.children { sub.addItem(nsItem(child)) }
            ns.submenu = sub
            ns.action = nil
        }
        return ns
    }

    // Clicking a message shouldn't leave an old selection highlighted in
    // other bubbles: losing focus clears the selection.
    override func resignFirstResponder() -> Bool {
        setSelectedRange(NSRange(location: 0, length: 0))
        return super.resignFirstResponder()
    }
}

/// An NSMenuItem that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: (() -> Void)?
    init(title: String, handler: (() -> Void)?) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func run() { handler?() }
}
