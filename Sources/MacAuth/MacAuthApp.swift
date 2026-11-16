import AppKit
import AuthCore
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
        if args.contains("--print-settings") {
            MainActor.assumeIsolated { SettingsProbe.run() }
            return
        }
        if let i = args.firstIndex(of: "--appearance"), args.indices.contains(i + 1) {
            NSApplication.shared.appearance = NSAppearance(named: args[i + 1] == "dark" ? .darkAqua : .aqua)
        }
        MacAuthApp.main()
    }

    /// `--demo`: the real window with invented accounts, entirely in memory (no vault, keychain or Secure Enclave).
    static var isDemo: Bool { CommandLine.arguments.contains("--demo") }
}

/// What Sparkle's delegates report, reduced to values that can cross into the main actor.
enum UpdateEvent: Sendable {
    /// A valid update was found (scheduled or user-initiated check).
    case found(version: String)
    /// The update is downloaded and will be installed when the app quits (automatic installation).
    case readyToInstall(version: String)
    /// Installed, skipped, or no longer offered: the notice goes away.
    case cleared
}

/// Sparkle callbacks. Sparkle calls them on the main thread; they only forward value-type events.
///
/// Gentle reminders: for scheduled (background) checks Sparkle never opens its own window, it only tells us
/// that an update exists (`standardUserDriverShouldHandleShowingScheduledUpdate` returns false). The window comes
/// up when the user asks for it, which is also what keeps the lock screen free of surprise windows.
final class UpdateDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, @unchecked Sendable {
    var onEvent: (@Sendable (UpdateEvent) -> Void)?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        onEvent?(.found(version: item.displayVersionString))
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        onEvent?(.readyToInstall(version: item.displayVersionString))
        return false   // Sparkle keeps its scheduler running and installs on quit
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        // Dismissing ("Später") keeps the notice; installing or skipping ends it.
        if choice != .dismiss { onEvent?(.cleared) }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        onEvent?(.cleared)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error = error as NSError?, error.domain == SUSparkleErrorDomain, error.code == Int(SUError.noUpdateError.rawValue) {
            onEvent?(.cleared)   // the server no longer offers anything newer than what runs
        }
    }
}

/// Sparkle updater. Without a public EdDSA key there is nothing to verify updates against: checking stays off.
@MainActor @Observable
final class UpdaterModel {
    /// An update Sparkle has found and the user has not installed or skipped yet.
    struct Pending: Equatable {
        /// Sanitised (`AppPolicy.displayVersion`); empty if the appcast's text was not usable.
        var version: String
        /// Already downloaded; installs when MacAuth quits.
        var ready: Bool
    }

    @ObservationIgnored private let delegate = UpdateDelegate()
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var started = false
    private(set) var canCheck = false
    private(set) var automaticChecks = false
    private(set) var automaticInstall = false
    /// Whether Sparkle allows the automatic-install option right now (needs automatic checks).
    private(set) var canAutomaticInstall = false
    private(set) var pending: Pending?

    /// Demo and documentation renders: no updater, optionally with an invented pending update.
    init(enabled: Bool = true, demoPending: Pending? = nil) {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: delegate)
        pending = demoPending
        guard enabled else { return }
        delegate.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        if !(key ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            controller.startUpdater()
            started = true
        }
        let updater = controller.updater
        refresh()
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            updater.observe(\.allowsAutomaticUpdates, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
        ]
        if started { scheduleLaunchCheck() }
    }

    private func refresh() {
        let updater = controller.updater
        canCheck = updater.canCheckForUpdates
        automaticChecks = updater.automaticallyChecksForUpdates
        canAutomaticInstall = updater.allowsAutomaticUpdates
        automaticInstall = updater.automaticallyDownloadsUpdates
    }

    private func handle(_ event: UpdateEvent) {
        switch event {
        case .found(let raw):
            // The appcast is not signed: only a short, harmless version string is ever shown ("" = show no version).
            let version = AppPolicy.displayVersion(raw) ?? ""
            pending = Pending(version: version, ready: pending?.version == version && pending?.ready == true)
        case .readyToInstall(let raw): pending = Pending(version: AppPolicy.displayVersion(raw) ?? "", ready: true)
        case .cleared: pending = nil
        }
    }

    /// Sparkle's own schedule waits out the rest of the interval after a launch. One quiet background check a
    /// few seconds after launch makes a new release show up promptly. It never opens a window (gentle reminders),
    /// and a relaunch within a quarter of an hour does not ask the server again.
    private func scheduleLaunchCheck() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let updater = self?.controller.updater, updater.automaticallyChecksForUpdates, !updater.sessionInProgress else { return }
            if let last = updater.lastUpdateCheckDate, Date().timeIntervalSince(last) < 15 * 60 { return }
            updater.checkForUpdatesInBackground()
        }
    }

    func setAutomaticChecks(_ on: Bool) {
        guard on != controller.updater.automaticallyChecksForUpdates else { return }
        controller.updater.automaticallyChecksForUpdates = on
        refresh()
    }

    func setAutomaticInstall(_ on: Bool) {
        guard on != controller.updater.automaticallyDownloadsUpdates else { return }
        controller.updater.automaticallyDownloadsUpdates = on
        refresh()
    }

    /// Menu item, settings button and the sidebar notice: with an update already shown, Sparkle brings its window forward.
    func checkForUpdates() { controller.checkForUpdates(nil) }
}

struct MacAuthApp: App {
    @State private var model = MacAuthApp.makeModel()
    @State private var updater = UpdaterModel(enabled: !Entry.isDemo)

    @MainActor
    private static func makeModel() -> AppModel {
        guard Entry.isDemo else { return AppModel() }
        // Ephemeral preferences: nothing of the demo is stored, screen protection is off so it can be captured.
        let suite = "com.fbrogno.macauth.demo.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults, domain: suite)
        settings.protectScreen = false
        settings.lastAccountChange = 2
        settings.lastBackupExport = 1
        return AppModel(demoPhase: .unlocked, accounts: DemoData.accounts, groups: DemoData.groups, settings: settings)
    }

    var body: some Scene {
        Window("MacAuth", id: "main") {
            RootView(model: model, updater: updater)
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
            Button("Aus Microsoft Authenticator umziehen …") { model.sheet = .microsoftGuide }.disabled(!canAdd)
            Button("Aus Datei importieren …") { Task { await ImportFlow.chooseFile(model: model) } }.disabled(!canAdd)
            // On the lock screen after a failed unlock this is the replacement path (the old file is kept, with its own confirmation).
            Button("Backup wiederherstellen …") { model.sheet = .restoreBackup(preset: nil, replace: model.phase == .locked) }
                .disabled(!(canAdd || model.canReplaceVault))
            Divider()
            Button("Backup exportieren …") { Task { await BackupFlow.startExport(model) } }
                .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!unlocked || model.accounts.isEmpty)
            Button("Auf Handy übertragen …") { Task { await BackupFlow.startTransfer(model) } }.disabled(!unlocked || model.accounts.isEmpty)
            Button("Für andere App exportieren (unverschlüsselt) …") { Task { await BackupFlow.startPlainExport(model) } }
                .disabled(!unlocked || model.accounts.isEmpty)
            Divider()
            Button("Sperren") { model.lock() }.keyboardShortcut("l").disabled(!unlocked || model.isDemo)
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
                } else if canAdd, model.sheet == nil || model.sheet?.isImportGuide == true {
                    // Also with the import sheet open: its guides tell the user to paste a QR code with ⌘V.
                    ImportFlow.paste(model: model)
                }
            }
            .keyboardShortcut("v")
            Button("Alles auswählen") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }.keyboardShortcut("a")
            Divider()
            Button("Nächsten Code kopieren") { model.copy(model.selection, next: true) }
                .keyboardShortcut("c", modifiers: [.command, .option]).disabled(!unlocked)
            Button("Suchen") { model.focusSearch() }.keyboardShortcut("f").disabled(!unlocked)
            // No ⌘⌫ here: in a text field it deletes text. The card list handles ⌘⌫ itself (MainView), only without text focus.
            Button("Konto löschen …") { if let id = model.selection { model.sheet = .confirmDelete(id) } }
                .disabled(!unlocked || model.selection == nil)
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
