import AppKit
import QuickbarCore

/// The bar itself: one text field over a results table.
///
/// Every keystroke bumps `generation` and hands the query to the search queue;
/// results come back to the main thread and are dropped if a newer keystroke
/// has happened since. The main thread never waits on anything.
final class LauncherController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let width: CGFloat = 680
    static let barHeight: CGFloat = 54
    static let rowHeight: CGFloat = 44
    static let maxVisibleRows = 8
    static let listPadding: CGFloat = 6

    let panel = FloatingPanel(size: NSSize(width: LauncherController.width, height: LauncherController.barHeight))
    private let field = NSTextField()
    private let chip = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private let table: ResultsTableView
    private let scroll: NSScrollView

    private var rows: [Item] = []
    private var mode: LauncherMode = .root
    private var lastText = ""
    private var suggestions: [String] = []
    /// Row to select once the next results arrive (used when moving between folders).
    private var pendingSelectionID: String?

    private let engine = QueryEngine()
    private let searchQueue = DispatchQueue(label: "quickbar.search", qos: .userInteractive)
    private let generationLock = NSLock()
    private var generation: UInt64 = 0
    private let suggestClient = SuggestClient()
    private var retypeTimer: Timer?

    /// Performs built-in actions ("settings", "quit", ...).
    var actionHandler: ((String) -> Void)?

    override init() {
        (table, scroll) = NSTableView.makeResultsTable(rowHeight: Self.rowHeight)
        super.init()
        buildViews()
    }

    private func buildViews() {
        guard let content = panel.contentView else { return }
        panel.delegate = self

        chip.font = .systemFont(ofSize: 13, weight: .semibold)
        chip.textColor = .secondaryLabelColor
        chip.lineBreakMode = .byTruncatingHead
        chip.setContentHuggingPriority(.required, for: .horizontal)
        chip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chip.isHidden = true

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .regular)
        field.placeholderString = "Quickbar"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false

        let bar = NSStackView(views: [chip, field])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)

        separator.boxType = .separator
        separator.isHidden = true

        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)

        for v in [bar, separator, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
            chip.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            separator.topAnchor.constraint(equalTo: bar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: Self.listPadding),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.listPadding),
        ])

        panel.keyEquivalentHandler = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
    }

    // MARK: - Show / hide

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    func show() {
        // Always come back to the index, keeping the last abbreviation selected
        // so Enter repeats it and typing replaces it.
        if mode != .root {
            setMode(.root)
            field.stringValue = ""
            lastText = ""
            refresh()
        }
        panel.position(height: currentHeight())
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        retypeTimer?.invalidate()
        suggestClient.cancel()
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    /// The index changed underneath us; re-run the current query.
    func indexDidUpdate() {
        if panel.isVisible, mode == .root, !field.stringValue.isEmpty { refresh(keepSelection: true) }
    }

    // MARK: - Query

    private func setMode(_ newMode: LauncherMode) {
        mode = newMode
        suggestions = []
        suggestClient.cancel()
        switch newMode {
        case .root:
            chip.isHidden = true
            field.placeholderString = "Quickbar"
        case .browse(let path):
            chip.stringValue = PathDisplay.abbreviate(path) + "  ▸"
            chip.isHidden = false
            field.placeholderString = ""
        case .text(let template):
            chip.stringValue = template.name + "  ▸"
            chip.isHidden = false
            field.placeholderString = "Search \(template.name)"
        }
        searchQueue.async { [engine] in engine.invalidateDirectoryCache() }
    }

    private func setText(_ text: String) {
        field.stringValue = text
        lastText = text
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    private func nextGeneration() -> UInt64 {
        generationLock.lock(); defer { generationLock.unlock() }
        generation &+= 1
        return generation
    }

    private func isCurrent(_ gen: UInt64) -> Bool {
        generationLock.lock(); defer { generationLock.unlock() }
        return gen == generation
    }

    private func refresh(keepSelection: Bool = false, fetchSuggestions: Bool = true) {
        let gen = nextGeneration()
        let query = field.stringValue
        let mode = mode
        let config = ConfigStore.shared.config
        let index = IndexManager.shared.index
        let suggestions = suggestions
        let keepID = keepSelection ? selectedItem?.id : nil

        searchQueue.async { [weak self, engine] in
            // Skip work for keystrokes that have already been superseded.
            guard let self, self.isCurrent(gen) else { return }
            let rows = engine.rows(mode: mode, query: query, config: config, index: index, suggestions: suggestions)
            DispatchQueue.main.async {
                guard self.isCurrent(gen) else { return }
                self.apply(rows, selecting: self.pendingSelectionID ?? keepID)
                self.pendingSelectionID = nil
            }
        }

        if fetchSuggestions, case .text(let template) = mode {
            suggestClient.fetch(template: template, query: query) { [weak self] result in
                guard let self, self.mode == mode, self.field.stringValue == query else { return }
                self.suggestions = result
                self.refresh(keepSelection: true, fetchSuggestions: false)
            }
        }
    }

    private func apply(_ newRows: [Item], selecting id: String?) {
        rows = newRows
        table.reloadData()
        separator.isHidden = rows.isEmpty
        if !rows.isEmpty {
            let row = id.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
            select(row)
        }
        panel.setHeight(currentHeight())
    }

    private func currentHeight() -> CGFloat {
        guard !rows.isEmpty else { return Self.barHeight }
        let visible = CGFloat(min(rows.count, Self.maxVisibleRows))
        return Self.barHeight + 1 + visible * Self.rowHeight + 2 * Self.listPadding
    }

    private var selectedItem: Item? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }

    private func select(_ row: Int) {
        guard rows.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let current = table.selectedRow
        select(min(max(current + delta, 0), rows.count - 1))
    }

    // MARK: - Text field

    func controlTextDidChange(_ notification: Notification) {
        let text = field.stringValue
        let previous = lastText
        lastText = text

        // Space after an abbreviation that selected a search template starts typing its query.
        if mode == .root, text == previous + " ", !previous.isEmpty, !previous.contains(" "),
           let item = selectedItem, item.kind == .searchTemplate,
           let template = item.payload.flatMap(ConfigStore.shared.config.template(withID:)) {
            learn(item, query: previous)
            enterTextMode(template, text: "")
            return
        }

        refresh()
        scheduleRetype()
    }

    /// After a pause the typed abbreviation is selected, so the next keystroke
    /// starts over instead of appending — LaunchBar's retype delay.
    private func scheduleRetype() {
        retypeTimer?.invalidate()
        if case .text = mode { return }
        let text = field.stringValue
        guard !text.isEmpty, !QueryEngine.isSticky(text) else { return }
        let delay = max(ConfigStore.shared.config.retypeDelay, 0.2)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.panel.isVisible, self.field.stringValue == text else { return }
            self.field.currentEditor()?.selectAll(nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        retypeTimer = timer
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
            moveSelection(by: Self.maxVisibleRows)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            moveSelection(by: -Self.maxVisibleRows)
        case #selector(NSResponder.insertNewline(_:)):
            execute(pin: false, reveal: false)
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // Option-Enter: open and make this the permanent target of the typed abbreviation.
            execute(pin: true, reveal: false)
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
        case #selector(NSResponder.insertTab(_:)):
            tab()
        case #selector(NSResponder.insertBacktab(_:)):
            return goToParent()
        case #selector(NSResponder.moveRight(_:)):
            return drillIntoSelection(textView: textView)
        case #selector(NSResponder.moveLeft(_:)):
            if case .text = mode { return false }
            if mode == .root, QueryEngine.isSticky(field.stringValue), !isPathQuery { return false }
            return goToParent()
        case #selector(NSResponder.deleteBackward(_:)):
            guard field.stringValue.isEmpty, mode != .root else { return false }
            setMode(.root)
            refresh()
        default:
            return false
        }
        return true
    }

    private var isPathQuery: Bool {
        let t = field.stringValue
        return t.hasPrefix("/") || t.hasPrefix("~")
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return false }
        switch event.keyCode {
        case 36, 76: // Return, Enter
            execute(pin: false, reveal: true)
            return true
        case 43: // comma
            hide()
            actionHandler?("settings")
            return true
        default:
            return false
        }
    }

    @objc private func rowDoubleClicked() {
        if table.clickedRow >= 0 {
            select(table.clickedRow)
            execute(pin: false, reveal: false)
        }
    }

    // MARK: - Navigation

    private func enterTextMode(_ template: SearchTemplate, text: String) {
        retypeTimer?.invalidate()
        setMode(.text(template: template))
        setText(text)
        refresh()
    }

    private func browse(_ path: String, selecting id: String? = nil) {
        retypeTimer?.invalidate()
        setMode(.browse(path: path))
        setText("")
        pendingSelectionID = id
        refresh()
    }

    private func tab() {
        guard let item = selectedItem else { return }
        if case .text = mode { return }
        if item.kind == .searchTemplate, let t = item.payload.flatMap(ConfigStore.shared.config.template(withID:)) {
            enterTextMode(t, text: "")
        } else if item.kind == .folder, let path = item.path {
            browse(path)
        } else if mode == .root {
            // Tab on anything else: keep what was typed and search the web for it, with suggestions.
            let config = ConfigStore.shared.config
            if let t = config.template(withID: config.defaultSearchTemplate) ?? config.searchTemplates.first {
                enterTextMode(t, text: field.stringValue)
            }
        }
    }

    /// Right arrow: step into the selected folder.
    private func drillIntoSelection(textView: NSTextView) -> Bool {
        if case .text = mode { return false }
        guard let item = selectedItem, item.kind == .folder, let path = item.path else { return false }
        // Only when the cursor is at the end, so the arrow still edits text otherwise.
        let range = textView.selectedRange()
        guard range.upperBound == (textView.string as NSString).length else { return false }
        browse(path)
        return true
    }

    /// Left arrow: show the folder containing the current folder or the selected item.
    private func goToParent() -> Bool {
        switch mode {
        case .text:
            return false
        case .browse(let path):
            guard path != "/" else { return true }
            browse((path as NSString).deletingLastPathComponent, selecting: path)
            return true
        case .root:
            guard let item = selectedItem, let path = item.path else { return false }
            browse((path as NSString).deletingLastPathComponent, selecting: item.id)
            return true
        }
    }

    // MARK: - Acting on the selection

    private func learn(_ item: Item, query: String) {
        guard mode == .root, !query.isEmpty, !QueryEngine.isSticky(query) else {
            if item.isFileSystemItem { Learning.store.recordUse(itemID: item.id); Learning.save() }
            return
        }
        Learning.store.record(query: query, itemID: item.id)
        Learning.save()
    }

    private func execute(pin: Bool, reveal: Bool) {
        guard let item = selectedItem else { return }
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        let config = ConfigStore.shared.config

        switch item.kind {
        case .searchTemplate:
            learn(item, query: query)
            if let t = item.payload.flatMap(config.template(withID:)) { enterTextMode(t, text: "") }
            return

        case .app, .file, .folder:
            guard let path = item.path else { return }
            learn(item, query: query)
            if pin, mode == .root, !query.isEmpty, !QueryEngine.isSticky(query) {
                var updated = config
                updated.abbreviations.removeAll { Fuzzy.normalize($0.abbreviation) == Fuzzy.normalize(query) }
                updated.abbreviations.append(CustomAbbreviation(abbreviation: Fuzzy.normalize(query), target: item.id))
                ConfigStore.shared.config = updated
            }
            hide()
            let url = URL(fileURLWithPath: path)
            if reveal {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                Opener.open(url)
            }

        case .webSearch:
            guard let text = item.payload,
                  let template = item.aux.flatMap(config.template(withID:)),
                  let url = template.searchURL(for: text)
            else { return }
            hide()
            Opener.open(url)

        case .url:
            guard let url = item.payload.flatMap(URL.init(string:)) else { return }
            hide()
            Opener.open(url)

        case .calculation:
            if let result = item.payload {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
            }
            hide()

        case .action:
            learn(item, query: query)
            hide()
            if let name = item.payload { actionHandler?(name) }
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ResultCell.identifier, owner: nil) as? ResultCell ?? ResultCell(frame: .zero)
        cell.configure(with: rows[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ResultRowView()
    }

    // MARK: - Debugging

    /// Types `text` as if the user had, for snapshots and smoke tests.
    func debugType(_ text: String) {
        field.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    func debugSendCommand(_ selector: Selector) {
        // Headless runs have no field editor; stand in one with the cursor at the end.
        let editor = field.currentEditor() as? NSTextView ?? {
            let stand = NSTextView()
            stand.string = field.stringValue
            stand.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
            return stand
        }()
        if !control(field, textView: editor, doCommandBy: selector),
           selector == #selector(NSResponder.deleteBackward(_:)) {
            debugType(String(field.stringValue.dropLast()))
        }
    }

    var debugRows: [Item] { rows }
    var debugSelectedRow: Int { table.selectedRow }
}

/// Opens things without making the main thread wait on Launch Services.
enum Opener {
    private static let queue = DispatchQueue(label: "quickbar.open", qos: .userInitiated)

    static func open(_ url: URL) {
        queue.async {
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { NSLog("Quickbar: could not open \(url): \(error.localizedDescription)") }
            }
        }
    }
}
