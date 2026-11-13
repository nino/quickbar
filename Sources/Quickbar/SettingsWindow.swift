import AppKit
import QuickbarCore
import ServiceManagement
import SwiftUI

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView().environmentObject(ConfigStore.shared))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Quickbar Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            FoldersTab().tabItem { Label("Index", systemImage: "folder") }
            AbbreviationsTab().tabItem { Label("Abbreviations", systemImage: "character.cursor.ibeam") }
            SearchTab().tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
        .frame(width: 640, height: 480)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var store: ConfigStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Hotkeys") {
                LabeledContent("Show Quickbar") { HotKeyRecorder(spec: $store.config.hotKey) }
                LabeledContent("Clipboard history") { HotKeyRecorder(spec: $store.config.clipboardHotKey) }
                Text("Add Shift to the clipboard hotkey to cycle backwards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Typing") {
                LabeledContent("Retype delay") {
                    HStack {
                        Slider(value: $store.config.retypeDelay, in: 0.3...3.0, step: 0.1)
                        Text(String(format: "%.1f s", store.config.retypeDelay))
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Text("After this long without typing, the next key starts a new abbreviation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Clipboard") {
                Stepper("Keep \(store.config.clipboardMaxEntries) entries",
                        value: $store.config.clipboardMaxEntries, in: 10...1000, step: 10)
                Toggle("Remember history across restarts", isOn: $store.config.clipboardPersist)
                Button("Clear History") { ClipboardStore.shared.clear() }
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
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
                        Text(folder.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Stepper("Depth \(folder.depth)", value: $folder.depth, in: 1...6).fixedSize()
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
                Text("Depth is how many levels below the folder are searchable. You can still walk deeper with the arrow keys.")
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
                Text("Applications are indexed from: \(store.config.applicationFolders.joined(separator: ", ")). Edit config.json to change that list.")
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
                    TextField("Abbreviation", text: $newAbbreviation).frame(width: 140)
                    Button("Choose Target…") { chooseTarget() }
                        .disabled(Fuzzy.normalize(newAbbreviation).isEmpty)
                }
            } header: {
                Text("Custom abbreviations")
            } footer: {
                Text("These always win. In the bar, ⌥↩ opens the selected item and assigns it to what you typed.")
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
                Text("Choosing an item three times for the same abbreviation makes it the first choice.")
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
                Text("Use {query} where the search terms go. A suggestions URL must return OpenSearch JSON; leave it empty for none.")
            }
        }
        .formStyle(.grouped)
    }
}
