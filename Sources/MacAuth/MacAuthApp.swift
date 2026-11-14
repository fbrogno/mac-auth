import AppKit
import Sparkle
import SwiftUI

/// Entry point: `--render-docs <dir>` draws the documentation images from demo data and exits;
/// everything else starts the app.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-docs") {
            let dir = args.indices.contains(i + 1) ? args[i + 1] : "docs/images"
            MainActor.assumeIsolated { DocRenderer.render(to: dir) }
            return
        }
        MacAuthApp.main()
    }
}

/// Sparkle updater. Without a public EdDSA key there is nothing to verify updates against: checking stays off.
@MainActor @Observable
final class UpdaterModel {
    @ObservationIgnored private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    @ObservationIgnored private var observation: NSKeyValueObservation?
    private(set) var canCheck = false

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        if !(key ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            controller.startUpdater()
        }
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = can }
        }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}

struct MacAuthApp: App {
    @State private var model = AppModel()
    @State private var updater = UpdaterModel()

    var body: some Scene {
        Window("MacAuth", id: "main") {
            RootView(model: model)
        }
        .defaultSize(width: 980, height: 660)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(model: model, updater: updater) }

        Settings {
            SettingsView(model: model, updater: updater)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    let updater: UpdaterModel

    private var unlocked: Bool { model.phase == .unlocked }
    private var canAdd: Bool { model.phase == .unlocked || model.phase == .firstRun }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Nach Updates suchen …") { updater.checkForUpdates() }.disabled(!updater.canCheck)
        }
        CommandGroup(replacing: .newItem) {
            Button("Neues Konto …") { model.sheet = .add }.keyboardShortcut("n").disabled(!canAdd)
            Button("Neue Gruppe …") { model.sheet = .newGroup }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!unlocked)
            Divider()
            Button("Importieren …") { model.sheet = .importer }.keyboardShortcut("i", modifiers: [.command, .shift]).disabled(!canAdd)
            Button("Backup wiederherstellen …") { model.sheet = .restoreBackup }.disabled(!canAdd)
            Divider()
            Button("Backup exportieren …") { Task { await BackupFlow.startExport(model) } }
                .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!unlocked || model.accounts.isEmpty)
            Button("Auf Handy übertragen …") { Task { await BackupFlow.startTransfer(model) } }.disabled(!unlocked || model.accounts.isEmpty)
            Divider()
            Button("Sperren") { model.lock() }.keyboardShortcut("l").disabled(!unlocked)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Ausschneiden") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }.keyboardShortcut("x")
            Button("Kopieren") {
                if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.selectedRange().length > 0 {
                    text.copy(nil)
                } else if unlocked, model.sheet == nil {
                    model.copy(model.selection)
                }
            }
            .keyboardShortcut("c")
            Button("Einfügen") {
                if NSApp.keyWindow?.firstResponder is NSTextView {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                } else if canAdd, model.sheet == nil {
                    ImportFlow.paste(model: model)
                }
            }
            .keyboardShortcut("v")
            Button("Alles auswählen") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }.keyboardShortcut("a")
            Divider()
            Button("Nächsten Code kopieren") { model.copy(model.selection, next: true) }
                .keyboardShortcut("c", modifiers: [.command, .option]).disabled(!unlocked)
            Button("Suchen") { model.focusSearch() }.keyboardShortcut("f").disabled(!unlocked)
            Button("Konto löschen …") { if let id = model.selection { model.sheet = .confirmDelete(id) } }
                .keyboardShortcut(.delete, modifiers: .command).disabled(!unlocked || model.selection == nil)
        }
        CommandGroup(after: .toolbar) {
            Picker("Darstellung", selection: Binding(get: { model.settings.listMode }, set: { model.settings.listMode = $0 })) {
                Text("Als Raster").tag(false)
                Text("Als Liste").tag(true)
            }
            .pickerStyle(.inline)
            .disabled(!unlocked)
        }
    }
}
