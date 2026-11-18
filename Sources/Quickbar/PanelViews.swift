import AppKit
import QuickbarCore

/// Borderless floating panel that takes keyboard focus without activating the
/// app, so the app you were in stays frontmost.
final class FloatingPanel: NSPanel {
    /// Return true to consume the event.
    var keyEquivalentHandler: ((NSEvent) -> Bool)?
    var keyDownHandler: ((NSEvent) -> Bool)?

    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        // Rounding the layer does not clip the blur itself, which then shows as
        // light wedges outside the corners. A mask image clips blur and shadow.
        effect.maskImage = Self.roundedMask(radius: Theme.cornerRadius)
        effect.autoresizingMask = [.width, .height]
        // A hairline edge keeps the panel defined over busy or same-coloured backgrounds.
        let edge = TintedBox(fill: .clear, radius: Theme.cornerRadius, border: NSColor.labelColor.withAlphaComponent(0.14))
        edge.passesClicksThrough = true
        edge.frame = effect.bounds
        edge.autoresizingMask = [.width, .height]
        effect.addSubview(edge)
        contentView = effect
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyEquivalentHandler?(event) == true { return true }
        // The panels never make Quickbar the active app, so the menu's ⌘Q
        // would go to whichever app is in front. Handle it here.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.keyCode == 12 {
            Log.info("quit by ⌘Q")
            NSApp.terminate(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if keyDownHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    /// Places the panel's top edge at a fixed spot on the screen with the mouse,
    /// so it grows downward as results appear.
    func position(height: CGFloat, on screen: NSScreen? = nil) {
        let screen = screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let width = frame.width
        let top = visible.maxY - (visible.height * 0.18).rounded()
        setFrame(NSRect(x: (visible.midX - width / 2).rounded(), y: top - height, width: width, height: height), display: true)
        invalidateShadow()
    }

    /// Resizes keeping the top edge where it is.
    func setHeight(_ height: CGFloat) {
        guard abs(frame.height - height) > 0.5 else { return }
        setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: true)
        invalidateShadow()
    }
}

/// Table that never takes focus away from the text field.
final class ResultsTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

final class ResultRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: Theme.selectionInset, dy: 1), xRadius: Theme.selectionRadius, yRadius: Theme.selectionRadius).fill()
    }
}

final class ResultCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ResultCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private(set) var itemID = ""
    private var titleText = ""
    private var titleHighlights: [Range<Int>] = []
    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private static let matchFont = NSFont.systemFont(ofSize: 13, weight: .bold)
    private static let titleParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        // Symbols keep their own size; file icons are already rasterized at row size.
        icon.imageScaling = .scaleProportionallyDown
        title.font = Self.titleFont
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11)
        detail.alignment = .right
        detail.setContentHuggingPriority(.required, for: .horizontal)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        // One line per row: the name, then where it is. The location gives way first.
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        for v in [icon, title, subtitle, detail] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let inset = Theme.contentInset
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: IconCache.pointSize),
            icon.heightAnchor.constraint(equalToConstant: IconCache.pointSize),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -10),
            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            subtitle.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -10),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            detail.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        renderTitle(selected: selected)
        subtitle.textColor = selected ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor
        detail.textColor = selected ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor
        icon.contentTintColor = selected ? .white : .secondaryLabelColor
    }

    /// The title with the matched characters in bold. When something matched,
    /// the rest steps back a little so the match carries the eye.
    private func renderTitle(selected: Bool) {
        let base: NSColor = selected ? .white : .labelColor
        guard !titleHighlights.isEmpty else {
            title.textColor = base
            title.stringValue = titleText
            return
        }
        // withAlphaComponent freezes a dynamic colour for whatever appearance is
        // current, which is not always this view's; resolve it for the view.
        var dimmed = base
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dimmed = base.withAlphaComponent(selected ? 0.82 : 0.72)
        }
        let text = NSMutableAttributedString(string: titleText, attributes: [
            .font: Self.titleFont,
            .foregroundColor: dimmed,
            .paragraphStyle: Self.titleParagraph,
        ])
        let length = text.length
        for r in titleHighlights where r.upperBound <= length {
            text.addAttributes([.font: Self.matchFont, .foregroundColor: base],
                               range: NSRange(location: r.lowerBound, length: r.count))
        }
        title.attributedStringValue = text
    }

    /// What the row is, shown at the trailing edge.
    private static func kindLabel(for item: Item) -> String {
        switch item.kind {
        case .app: return "Application"
        case .folder: return "Folder"
        case .file:
            let ext = (item.title as NSString).pathExtension
            return ext.isEmpty || ext.count > 5 ? "File" : ext.uppercased()
        case .searchTemplate: return "Search"
        case .webSearch: return ""
        case .url: return "Link"
        case .calculation: return "Result"
        case .action: return "Command"
        case .setting: return "Settings"
        }
    }

    func configure(with item: Item, highlights: [Range<Int>] = []) {
        itemID = item.id
        titleText = item.title
        titleHighlights = highlights
        renderTitle(selected: backgroundStyle == .emphasized)
        subtitle.stringValue = item.subtitle
        detail.stringValue = Self.kindLabel(for: item)

        if let image = IconCache.shared.immediate(for: item) {
            icon.image = image
        } else {
            icon.image = nil
            let id = item.id
            IconCache.shared.load(item) { [weak self] image in
                if self?.itemID == id { self?.icon.image = image }
            }
        }
    }
}

// MARK: - Shared chrome

enum Theme {
    // Dense on purpose, after the old Spotlight menu and LaunchBar: small
    // single-line rows, so more results fit and the eye travels less.
    static let cornerRadius: CGFloat = 10
    /// Gap between the panel edge and the selection highlight.
    static let selectionInset: CGFloat = 5
    static let selectionRadius: CGFloat = 5
    /// Where row content, headers and footer hints start, from the panel edge.
    static let contentInset: CGFloat = selectionInset + 7
    static let footerHeight: CGFloat = 22
}

/// A rounded, tinted rectangle whose colours follow light/dark changes.
/// (Layer colours are static CGColors, so they are re-resolved in `updateLayer`.)
final class TintedBox: NSView {
    private let fill: NSColor
    private let border: NSColor?
    private let radius: CGFloat
    var passesClicksThrough = false

    init(fill: NSColor, radius: CGFloat, border: NSColor? = nil) {
        self.fill = fill
        self.border = border
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = radius
        layer.backgroundColor = fill.cgColor
        layer.borderColor = border?.cgColor
        layer.borderWidth = border == nil ? 0 : 1
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesClicksThrough ? nil : super.hitTest(point)
    }
}

/// The strip at the bottom of a panel that says what the keys do right now.
/// Slots are created once; updating only sets strings.
final class KeyHintBar: NSView {
    struct Hint: Equatable {
        let key: String
        let label: String
    }

    private final class Slot {
        let cap = TintedBox(fill: NSColor.labelColor.withAlphaComponent(0.09), radius: 3)
        let key = NSTextField(labelWithString: "")
        let label = NSTextField(labelWithString: "")
        let view = NSStackView()

        init() {
            key.font = .systemFont(ofSize: 10, weight: .medium)
            key.textColor = .secondaryLabelColor
            key.alignment = .center
            key.translatesAutoresizingMaskIntoConstraints = false
            cap.translatesAutoresizingMaskIntoConstraints = false
            cap.addSubview(key)
            label.font = .systemFont(ofSize: 10.5)
            label.textColor = .secondaryLabelColor
            NSLayoutConstraint.activate([
                key.leadingAnchor.constraint(equalTo: cap.leadingAnchor, constant: 4),
                key.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: -4),
                key.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
                cap.heightAnchor.constraint(equalToConstant: 15),
                cap.widthAnchor.constraint(greaterThanOrEqualToConstant: 17),
            ])
            view.orientation = .horizontal
            view.spacing = 4
            view.addArrangedSubview(cap)
            view.addArrangedSubview(label)
        }

        func set(_ hint: Hint?) {
            view.isHidden = hint == nil
            key.stringValue = hint?.key ?? ""
            label.stringValue = hint?.label ?? ""
        }
    }

    private let slots: [Slot]
    private let trailingSlot = Slot()
    private var current: [Hint] = []

    init(slots count: Int = 4, trailing: Hint? = nil) {
        slots = (0..<count).map { _ in Slot() }
        super.init(frame: .zero)
        let leading = NSStackView(views: slots.map(\.view))
        leading.orientation = .horizontal
        leading.spacing = 12
        trailingSlot.set(trailing)
        for v in [leading, trailingSlot.view] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let inset = Theme.contentInset
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingSlot.view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            trailingSlot.view.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        slots.forEach { $0.set(nil) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ hints: [Hint]) {
        guard hints != current else { return }
        current = hints
        for (i, slot) in slots.enumerated() {
            slot.set(i < hints.count ? hints[i] : nil)
        }
    }
}

extension NSTableView {
    static func makeResultsTable(rowHeight: CGFloat) -> (ResultsTableView, NSScrollView) {
        let table = ResultsTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.usesAutomaticRowHeights = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        return (table, scroll)
    }
}
