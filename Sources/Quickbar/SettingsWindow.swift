import AppKit
import QuickbarCore
import ServiceManagement
import SwiftUI

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    /// Standard macOS preferences: a toolbar of panes, the window sized to each.
    func makeWindow() -> NSWindow {
        let tabs = SettingsTabController()
        tabs.tabStyle = .toolbar
        func add<V: View>(_ title: String, _ symbol: String, height: CGFloat, _ view: V) {
            let size = NSSize(width: SettingsLayout.width, height: height)
            let host = NSHostingController(rootView: view
                .frame(width: size.width, height: size.height)
                .environmentObject(ConfigStore.shared))
            host.preferredContentSize = size
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add("General", "gearshape", height: 590, GeneralTab())
        add("Index", "folder", height: 540, FoldersTab())
        add("Abbreviations", "character.cursor.ibeam", height: 460, AbbreviationsTab())
        add("Search", "magnifyingglass", height: 460, SearchTab())
        add("Snippets", "text.quote", height: 520, SnippetsTab())

        let w = NSWindow(contentViewController: tabs)
        w.title = "General"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Explanatory text under a section, left-aligned (the default trails).
private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum SettingsLayout {
    static let width: CGFloat = 560
    static let controlWidth: CGFloat = 170
}

/// Resizes the window to the selected pane, keeping its top edge in place.
final class SettingsTabController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let window = view.window, let item = tabViewItem,
              let size = item.viewController?.preferredContentSize, size.height > 0
        else { return }
        window.title = item.label
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var store: ConfigStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    /// The slider moves freely (a stepped slider draws a row of tick marks);
    /// the value is rounded to tenths on the way in.
    private var retypeDelay: Binding<Double> {
        Binding(get: { store.config.retypeDelay },
                set: { store.config.retypeDelay = ($0 * 10).rounded() / 10 })
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Show Quickbar") {
                    HotKeyRecorder(spec: $store.config.hotKey).frame(width: SettingsLayout.controlWidth)
                }
                LabeledContent("Clipboard history") {
                    HotKeyRecorder(spec: $store.config.clipboardHotKey).frame(width: SettingsLayout.controlWidth)
                }
            } header: {
                Text("Hotkeys")
            } footer: {
                Footnote("Click a shortcut, then press the new one. Shift steps backwards through the clipboard.")
            }
            Section {
                LabeledContent("Start over after a pause of") {
                    HStack(spacing: 8) {
                        Slider(value: retypeDelay, in: 0.3...3.0).frame(width: SettingsLayout.controlWidth - 52)
                        Text(String(format: "%.1f s", store.config.retypeDelay))
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            } header: {
                Text("Typing")
            } footer: {
                Footnote("After this pause, the next key starts a new abbreviation.")
            }
            Section("Clipboard") {
                LabeledContent("Entries to keep") {
                    HStack(spacing: 6) {
                        Text("\(store.config.clipboardMaxEntries)").monospacedDigit()
                        Stepper("Entries to keep", value: $store.config.clipboardMaxEntries, in: 10...1000, step: 10)
                            .labelsHidden()
                    }
                }
                Toggle("Remember history across restarts", isOn: $store.config.clipboardPersist)
                LabeledContent("History") {
                    Button("Clear…") { confirmClear() }
                }
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
            } header: {
                Text("Startup")
            } footer: {
                if let loginError {
                    Footnote(loginError).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear the clipboard history?"
        alert.informativeText = "All remembered entries are removed. This cannot be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { ClipboardStore.shared.clear() }
    }
}

/// Click, then press a key combination.
private struct HotKeyRecorder: NSViewRepresentable {
    @Binding var spec: HotKeySpec

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onChange = { spec = $0 }
        button.spec = spec
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onChange = { spec = $0 }
        if !button.isRecording { button.spec = spec }
    }
}

final class RecorderButton: NSButton {
    var spec = Config().hotKey { didSet { title = spec.displayString } }
    var onChange: ((HotKeySpec) -> Void)?
    private(set) var isRecording = false
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func toggleRecording() {
        isRecording ? stop() : start()
    }

    private func start() {
        isRecording = true
        title = "Type shortcut…"
        // Our own hotkeys would swallow the keys being recorded.
        AppDelegate.shared?.suspendHotKeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        title = spec.displayString
        AppDelegate.shared?.registerHotKeys()
    }

    private func record(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 && flags.isEmpty { // Escape cancels
            stop()
            return
        }
        let isFunctionKey = KeyNames.special[UInt32(event.keyCode)]?.hasPrefix("F") == true
        guard !flags.subtracting(.shift).isEmpty || isFunctionKey else {
            NSSound.beep()
            return
        }
        let new = HotKeySpec(
            keyCode: UInt32(event.keyCode),
            modifiers: KeyNames.modifierNames(flags),
            label: KeyNames.label(for: event))
        spec = new
        onChange?(new)
        stop()
    }
}

// MARK: - Index

private struct FoldersTab: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        Form {
            Section {
                ForEach($store.config.folders) { $folder in
                    HStack {
                        Image(systemName: "folder")
                        Text(folder.path).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                        Spacer()
                        Text(folder.depth == 1 ? "1 level" : "\(folder.depth) levels")
                            .monospacedDigit().foregroundStyle(.secondary)
                            // The path truncates to make room; this label must never wrap.
                            .lineLimit(1).fixedSize()
                        Stepper("Depth", value: $folder.depth, in: 1...6).labelsHidden()
                        Button(role: .destructive) {
                            store.config.folders.removeAll { $0.path == folder.path }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") { addFolder() }
            } header: {
                Text("Indexed folders")
            } footer: {
                Footnote("Levels are how deep below each folder items are searchable. The arrow keys still reach deeper.")
            }
            Section {
                TextField("Skip names", text: Binding(
                    get: { store.config.excludedNames.joined(separator: ", ") },
                    set: { store.config.excludedNames = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                ))
                LabeledContent("Indexed items", value: "\(IndexManager.shared.index.items.count)")
                Button("Rescan Now") { IndexManager.shared.rebuild() }
            } header: {
                Text("Details")
            } footer: {
                Footnote("Applications are indexed from: \(store.config.applicationFolders.joined(separator: ", ")). Edit config.json to change that list.")
            }
        }
        .formStyle(.grouped)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = PathDisplay.abbreviate(url.path)
            if !store.config.folders.contains(where: { $0.path == path }) {
                store.config.folders.append(IndexedFolder(path: path, depth: 1))
            }
        }
    }
}

// MARK: - Abbreviations

private func displayName(forTarget target: String) -> String {
    if let item = IndexManager.shared.index.item(withID: target) { return item.title }
    guard target.hasPrefix("/") else { return target }
    let name = (target as NSString).lastPathComponent
    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
}

private struct AbbreviationsTab: View {
    @EnvironmentObject var store: ConfigStore
    @State private var newAbbreviation = ""
    @State private var learned: [LearningStore.Learned] = []

    var body: some View {
        Form {
            Section {
                ForEach(store.config.abbreviations) { entry in
                    HStack {
                        Text(entry.abbreviation).font(.body.monospaced()).frame(width: 90, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(displayName(forTarget: entry.target))
                        Spacer()
                        Button(role: .destructive) {
                            store.config.abbreviations.removeAll { $0.id == entry.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Abbreviation", text: $newAbbreviation, prompt: Text("Abbreviation"))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 140)
                    Button("Choose Target…") { chooseTarget() }
                        .disabled(Fuzzy.normalize(newAbbreviation).isEmpty)
                }
            } header: {
                Text("Custom abbreviations")
            } footer: {
                Footnote("These always win. In the bar, ⌥↩ opens the selected item and assigns it to what you typed.")
            }
            Section {
                if learned.isEmpty {
                    Text("Nothing learned yet.").foregroundStyle(.secondary)
                }
                ForEach(learned) { entry in
                    HStack {
                        Text(entry.query).font(.body.monospaced()).frame(width: 90, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(displayName(forTarget: entry.itemID))
                        Spacer()
                        Text(entry.count >= LearningStore.dominantCount ? "first choice" : "\(entry.count)×")
                            .foregroundStyle(.secondary)
                        Button("Forget") {
                            Learning.store.forget(query: entry.query, itemID: entry.itemID)
                            Learning.save()
                            learned = Learning.store.learned()
                        }
                    }
                }
            } header: {
                Text("Learned from use")
            } footer: {
                Footnote("Choosing an item three times for the same abbreviation makes it the first choice.")
            }
        }
        .formStyle(.grouped)
        .onAppear { learned = Learning.store.learned() }
    }

    private func chooseTarget() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let abbreviation = Fuzzy.normalize(newAbbreviation)
        store.config.abbreviations.removeAll { Fuzzy.normalize($0.abbreviation) == abbreviation }
        store.config.abbreviations.append(CustomAbbreviation(abbreviation: abbreviation, target: url.path))
        newAbbreviation = ""
    }
}

// MARK: - Search

private struct SearchTab: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        Form {
            ForEach($store.config.searchTemplates) { $template in
                Section(template.name.isEmpty ? "New template" : template.name) {
                    TextField("Name", text: $template.name)
                    TextField("Search URL", text: $template.url)
                    TextField("Suggestions URL", text: Binding(
                        get: { template.suggestURL ?? "" },
                        set: { template.suggestURL = $0.isEmpty ? nil : $0 }
                    ))
                    HStack {
                        if store.config.defaultSearchTemplate == template.id {
                            Label("Default", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                        } else {
                            Button("Make Default") { store.config.defaultSearchTemplate = template.id }
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            store.config.searchTemplates.removeAll { $0.id == template.id }
                        }
                        .disabled(store.config.searchTemplates.count <= 1)
                    }
                }
            }
            Section {
                Button("Add Template") {
                    store.config.searchTemplates.append(SearchTemplate(
                        id: UUID().uuidString.lowercased(), name: "", url: "https://example.com/search?q={query}"))
                }
            } footer: {
                Footnote("Use {query} where the search terms go. A suggestions URL must return OpenSearch JSON; leave it empty for none.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Snippets

private struct SnippetsTab: View {
    @EnvironmentObject var store: ConfigStore
    @State private var selection: String?

    private var selected: Snippet? {
        store.config.snippets.first { $0.id == selection }
    }

    /// Looks the snippet up by id on every access: a binding into the array by
    /// position would crash when the selected snippet is removed.
    private func binding(_ id: String, _ field: WritableKeyPath<Snippet, String>) -> Binding<String> {
        Binding(
            get: { store.config.snippets.first { $0.id == id }?[keyPath: field] ?? "" },
            set: { value in
                guard let i = store.config.snippets.firstIndex(where: { $0.id == id }) else { return }
                store.config.snippets[i][keyPath: field] = value
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            List(selection: $selection) {
                ForEach(store.config.snippets) { snippet in
                    HStack(spacing: 8) {
                        Text(snippet.displayTitle.isEmpty ? "Empty snippet" : snippet.displayTitle)
                            .foregroundStyle(snippet.displayTitle.isEmpty ? Color.secondary : Color.primary)
                            .lineLimit(1)
                        if snippet.hasTitle {
                            Text(Snippet.preview(snippet.text, length: Snippet.previewLength))
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(snippet.id)
                }
                .onMove { store.config.snippets.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered)
            .frame(height: 170)

            HStack(spacing: 8) {
                Button { add() } label: { Image(systemName: "plus") }
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(selected == nil)
                Spacer()
            }

            if let snippet = selected {
                TextField("Title", text: binding(snippet.id, \.title), prompt: Text("Title (optional)"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                PlainTextEditor(text: binding(snippet.id, \.text))
                    // A fresh editor per snippet, so undo never crosses into another one.
                    .id(snippet.id)
            } else {
                Text(store.config.snippets.isEmpty ? "No snippets yet. Add one with +." : "Select a snippet to edit it.")
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Text("In the bar, ↩ pastes the selected snippet, ⌘↩ types it key by key (for fields that block pasting) and ⌘C copies it. Pasting and typing need Quickbar to be allowed under Privacy & Security › Accessibility.")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private func add() {
        let snippet = Snippet(text: "")
        store.config.snippets.append(snippet)
        selection = snippet.id
    }

    private func removeSelected() {
        guard let id = selection else { return }
        selection = nil
        store.config.snippets.removeAll { $0.id == id }
        store.config.abbreviations.removeAll { $0.target == Snippet.itemID(id) }
    }
}

/// A plain multi-line text box. SwiftUI's TextEditor applies the system's
/// smart quotes and dashes, which would alter commands and code kept as snippets.
private struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.textContainerInset = NSSize(width: 2, height: 5)
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // Setting the string moves the cursor to the end, so only when it differs.
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor

        init(_ parent: PlainTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}
