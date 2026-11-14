import AppKit
import AuthCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    var updater: UpdaterModel?
    @State private var confirmDisableAuth = false
    @State private var tab: Int

    init(model: AppModel, updater: UpdaterModel?, initialTab: Int = 0) {
        self.model = model
        self.updater = updater
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        let settings = model.settings
        TabView(selection: $tab) {
            securityForm(settings)
                .tabItem { Label("Sicherheit", systemImage: "lock.shield") }
                .tag(0)
            generalForm(settings)
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
                .tag(1)
        }
        .frame(width: 540, height: 660)
        .background(WindowConfigurator(isMainWindow: false))
        .environment(\.protectScreen, settings.protectScreen)
        .confirmationDialog(Text("Entsperren ohne Touch ID oder Passwort?"), isPresented: $confirmDisableAuth, titleVisibility: .visible) {
            Button("Abbrechen", role: .cancel) {}
            Button("Abfrage ausschalten", role: .destructive) { Task { await model.setRequireAuth(false) } }
        } message: {
            Text("Der Schlüssel wandert dann aus der Secure Enclave in den Schlüsselbund. Jeder, der an deinem entsperrten Mac sitzt, kommt an die Codes.")
        }
    }

    private var locked: Bool { model.phase != .unlocked }

    private var protectionText: (text: LocalizedStringKey, warn: Bool) {
        switch model.protection {
        case .secureEnclave:
            return ("Der Schlüssel liegt in der Secure Enclave deines Macs. Ohne Touch ID oder Passwort lässt sich der Tresor nicht öffnen.", false)
        case .keychain where model.secureEnclaveAvailable:
            return model.appLockRequired
                ? ("Der Schlüssel liegt im Schlüsselbund, nicht in der Secure Enclave. MacAuth fragt beim Öffnen nach Touch ID oder Passwort, der Schutz ist aber schwächer.", true)
                : ("Der Schlüssel liegt im Schlüsselbund. Wer an deinem entsperrten Mac sitzt, kann MacAuth ohne Abfrage öffnen.", true)
        case .keychain:
            return model.appLockRequired
                ? ("Dieser Mac hat keine Secure Enclave. Der Schlüssel liegt im Schlüsselbund, MacAuth fragt beim Öffnen aber nach Touch ID oder Passwort.", false)
                : ("Dieser Mac hat keine Secure Enclave. Der Schlüssel liegt im Schlüsselbund, MacAuth öffnet ohne Abfrage.", true)
        case .unknown:
            return ("Die Schutzart des Tresors steht erst nach dem Entsperren fest.", false)
        }
    }

    private func securityForm(_ settings: AppSettings) -> some View {
        Form {
            if locked {
                Section {
                    Label("MacAuth ist gesperrt. Entsperre es, um Sicherheitseinstellungen zu ändern.", systemImage: "lock")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Sicherheit") {
                Toggle("Entsperren mit Touch ID oder Passwort verlangen", isOn: Binding(
                    get: { model.effectiveRequireAuth },
                    set: { on in
                        if on { Task { await model.setRequireAuth(true) } } else { confirmDisableAuth = true }
                    }))
                .disabled(locked)
                Text(protectionText.text)
                    .font(.callout).foregroundStyle(protectionText.warn ? Color.orange : Color.secondary)
                Picker("Automatisch sperren", selection: Binding(get: { settings.autoLockMinutes }, set: { new in
                    let old = settings.autoLockMinutes
                    Task { await model.applySecuritySetting(.autoLockMinutes(from: old, to: new)) { settings.autoLockMinutes = new } }
                })) {
                    Text("Nach 1 Minute").tag(1)
                    Text("Nach 5 Minuten").tag(5)
                    Text("Nach 15 Minuten").tag(15)
                    Text("Nach 60 Minuten").tag(60)
                    Text("Nie").tag(0)
                }
                .disabled(locked)
                Text("Beim Ruhezustand, bei gesperrtem Bildschirm und beim Benutzerwechsel sperrt MacAuth immer. Weniger Schutz einzustellen verlangt eine Abfrage mit Touch ID oder Passwort.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Anzeige") {
                Toggle("Fenster bei Bildschirmfreigabe und Screenshots ausblenden", isOn: Binding(get: { settings.protectScreen }, set: { on in
                    let old = settings.protectScreen
                    Task { await model.applySecuritySetting(.protectScreen(from: old, to: on)) { settings.protectScreen = on } }
                }))
                .disabled(locked)
                Toggle("Codes erst bei Hover oder Auswahl zeigen", isOn: Binding(get: { settings.hideCodes }, set: { on in
                    let old = settings.hideCodes
                    Task { await model.applySecuritySetting(.hideCodes(from: old, to: on)) { settings.hideCodes = on } }
                }))
                .disabled(locked)
            }
        }
        .formStyle(.grouped)
    }

    private func generalForm(_ settings: AppSettings) -> some View {
        Form {
            Section("Kopieren") {
                Picker("Zwischenablage leeren nach", selection: Binding(get: { settings.clipboardClearSeconds }, set: { new in
                    let old = settings.clipboardClearSeconds
                    Task { await model.applySecuritySetting(.clipboardClearSeconds(from: old, to: new)) { settings.clipboardClearSeconds = new } }
                })) {
                    Text("10 Sekunden").tag(10)
                    Text("30 Sekunden").tag(30)
                    Text("60 Sekunden").tag(60)
                    Text("Nie").tag(0)
                }
                .disabled(locked)
                Toggle("Fenster nach dem Kopieren ausblenden", isOn: Binding(get: { settings.hideAfterCopy }, set: { settings.hideAfterCopy = $0 }))
            }
            Section("Tastenkombination") {
                Toggle("MacAuth mit einer Tastenkombination anzeigen", isOn: Binding(get: { settings.hotKeyEnabled }, set: { on in
                    settings.hotKeyEnabled = on
                    model.applyHotKey()
                }))
                if settings.hotKeyEnabled {
                    HStack {
                        Text("MacAuth anzeigen")
                        Spacer()
                        HotKeyRecorder(model: model)
                    }
                    if let error = model.hotKeyError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    }
                }
                Text("Die Kombination holt das Fenster nach vorn, wenn du es brauchst, und blendet es beim erneuten Drücken wieder aus. Sie braucht mindestens ⌘, ⌥ oder ⌃.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Import und Backup") {
                Picker("Standardgruppe für Importe", selection: Binding(get: { settings.defaultGroupID }, set: { settings.defaultGroupID = $0 })) {
                    Text("Keine Gruppe").tag("")
                    ForEach(model.groups) { group in Text(group.name).tag(group.id.uuidString) }
                }
                Toggle("An Backups erinnern", isOn: Binding(get: { settings.backupReminder }, set: { settings.backupReminder = $0 }))
            }
            Section("Updates") {
                Toggle("Automatisch nach Updates suchen", isOn: Binding(get: { updater?.automaticChecks ?? true }, set: { updater?.setAutomaticChecks($0) }))
                    .disabled(updater == nil)
                Toggle("Updates automatisch installieren", isOn: Binding(get: { updater?.automaticInstall ?? false }, set: { updater?.setAutomaticInstall($0) }))
                    .disabled(updater == nil || !(updater?.canAutomaticInstall ?? false))
                Text("Neue Versionen werden im Hintergrund geladen und beim nächsten Beenden von MacAuth installiert. Ohne diese Option zeigt MacAuth einen Hinweis in der Seitenleiste, und du entscheidest selbst.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Nach Updates suchen …") { updater?.checkForUpdates() }.disabled(!(updater?.canCheck ?? false))
                    Spacer()
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .foregroundStyle(.secondary).font(.callout)
                }
                Text("Das ist die einzige Verbindung, die MacAuth ins Internet aufbaut. Es werden keine Daten über dich gesendet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then press the shortcut. Esc cancels. Needs at least one of ⌘ ⌥ ⌃.
struct HotKeyRecorder: View {
    @Bindable var model: AppModel
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? String(localized: "Taste drücken …") : (model.settings.hotKeyLabel.isEmpty ? String(localized: "Aufnehmen") : model.settings.hotKeyLabel)) {
            recording ? stop() : start()
        }
        .font(.system(.body, design: .rounded))
        .onDisappear { stop() }
    }

    private func start() {
        model.pauseHotKey()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let characters = event.charactersIgnoringModifiers
            MainActor.assumeIsolated {
                if keyCode == 53 { stop(); return }   // Esc
                guard HotKeyService.isAcceptable(flags) else {
                    model.hotKeyError = String(localized: "Die Kombination braucht mindestens ⌘, ⌥ oder ⌃.")
                    return
                }
                let settings = model.settings
                settings.hotKeyCode = Int(keyCode)
                settings.hotKeyModifiers = Int(flags.rawValue)
                settings.hotKeyLabel = HotKeyLabel.text(keyCode: keyCode, modifiers: flags, characters: characters)
                stop()
            }
            return nil   // the key press never reaches the window
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            model.applyHotKey()
        }
    }
}
