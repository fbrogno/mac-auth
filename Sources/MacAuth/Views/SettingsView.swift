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
        .frame(width: 540, height: 500)
        .background(WindowConfigurator(isMainWindow: false))
        .environment(\.protectScreen, settings.protectScreen)
        .confirmationDialog(Text("Entsperren ohne Touch ID oder Passwort?"), isPresented: $confirmDisableAuth, titleVisibility: .visible) {
            Button("Abfrage ausschalten", role: .destructive) { Task { await model.setRequireAuth(false) } }
        } message: {
            Text("Der Schlüssel wandert dann aus der Secure Enclave in den Schlüsselbund. Jeder, der an deinem entsperrten Mac sitzt, kommt an die Codes.")
        }
    }

    private func securityForm(_ settings: AppSettings) -> some View {
        Form {
            Section("Sicherheit") {
                Toggle("Entsperren mit Touch ID oder Passwort verlangen", isOn: Binding(
                    get: { settings.requireAuth },
                    set: { on in
                        if on { Task { await model.setRequireAuth(true) } } else { confirmDisableAuth = true }
                    }))
                .disabled(model.phase != .unlocked)
                Group {
                    if settings.requireAuth {
                        Text("Der Schlüssel liegt in der Secure Enclave deines Macs. Ohne Touch ID oder Passwort lässt sich der Tresor nicht öffnen.")
                    } else {
                        Text("Der Schlüssel liegt im Schlüsselbund. Wer an deinem entsperrten Mac sitzt, kann MacAuth ohne Abfrage öffnen.")
                    }
                }
                .font(.callout).foregroundStyle(settings.requireAuth ? Color.secondary : Color.orange)
                Picker("Automatisch sperren", selection: Binding(get: { settings.autoLockMinutes }, set: { settings.autoLockMinutes = $0 })) {
                    Text("Nach 1 Minute").tag(1)
                    Text("Nach 5 Minuten").tag(5)
                    Text("Nach 15 Minuten").tag(15)
                    Text("Nach 60 Minuten").tag(60)
                    Text("Nie").tag(0)
                }
                Text("Beim Ruhezustand, bei gesperrtem Bildschirm und beim Benutzerwechsel sperrt MacAuth immer.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Anzeige") {
                Toggle("Fenster bei Bildschirmfreigabe und Screenshots ausblenden", isOn: Binding(get: { settings.protectScreen }, set: { settings.protectScreen = $0 }))
                Toggle("Codes erst bei Hover oder Auswahl zeigen", isOn: Binding(get: { settings.hideCodes }, set: { settings.hideCodes = $0 }))
            }
        }
        .formStyle(.grouped)
    }

    private func generalForm(_ settings: AppSettings) -> some View {
        Form {
            Section("Kopieren") {
                Picker("Zwischenablage leeren nach", selection: Binding(get: { settings.clipboardClearSeconds }, set: { settings.clipboardClearSeconds = $0 })) {
                    Text("10 Sekunden").tag(10)
                    Text("30 Sekunden").tag(30)
                    Text("60 Sekunden").tag(60)
                    Text("Nie").tag(0)
                }
                Toggle("Fenster nach dem Kopieren ausblenden", isOn: Binding(get: { settings.hideAfterCopy }, set: { settings.hideAfterCopy = $0 }))
            }
            Section("Import und Backup") {
                Picker("Standardgruppe für Importe", selection: Binding(get: { settings.defaultGroupID }, set: { settings.defaultGroupID = $0 })) {
                    Text("Keine Gruppe").tag("")
                    ForEach(model.groups) { group in Text(group.name).tag(group.id.uuidString) }
                }
                Toggle("An Backups erinnern", isOn: Binding(get: { settings.backupReminder }, set: { settings.backupReminder = $0 }))
            }
            Section("Updates") {
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
