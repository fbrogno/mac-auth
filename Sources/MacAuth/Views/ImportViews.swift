import AuthCore
import SwiftUI

struct ImportSheet: View {
    @Bindable var model: AppModel
    @State private var scanning = false
    @State private var cameraProblem: CameraAccess?
    @State private var cameraTicket: Ticket?
    @State private var confirmScreenshot = false
    /// Instructions for another source (Apple Passwords, another app's file, the move from Microsoft Authenticator);
    /// nil = the Google Authenticator guide.
    @State private var fileGuide: FileGuide?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    enum FileGuide { case applePasswords, otherApp, microsoft }

    /// Where Microsoft accounts add another authenticator app. Opened in the browser only on the user's click.
    private static let microsoftPersonalURL = URL(string: "https://account.microsoft.com/security")!
    private static let microsoftWorkURL = URL(string: "https://mysignins.microsoft.com/security-info")!

    init(model: AppModel, initialGuide: FileGuide? = nil) {
        self.model = model
        _fileGuide = State(initialValue: initialGuide)
    }

    private var importer: ImportCoordinator { model.importer }

    var body: some View {
        SheetScaffold(title: sheetTitle, subtitle: sheetSubtitle, width: 540) {
            VStack(alignment: .leading, spacing: 14) {
                if scanning {
                    cameraPage
                } else if let fileGuide {
                    switch fileGuide {
                    case .applePasswords: applePasswordsPage
                    case .otherApp: otherAppPage
                    case .microsoft: microsoftPage
                    }
                } else {
                    guidePage
                }
                progressAndNotice
            }
        } footer: {
            if scanning {
                Button("Zurück") { scanning = false }
            } else if fileGuide != nil {
                Button("Zurück") { fileGuide = nil; importer.reset() }
            } else {
                Button("Screenshot wählen …") { confirmScreenshot = true }
            }
            Spacer()
            Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
            if !scanning {
                if fileGuide == .microsoft {
                    Button("Schlüssel eingeben …") { model.sheet = .add }
                    Button("Einfügen") { ImportFlow.paste(model: model) }
                        .keyboardShortcut(.defaultAction).primaryButtonStyle()
                } else if fileGuide != nil {
                    Button("Datei wählen …") { Task { await ImportFlow.chooseFile(model: model) } }
                        .keyboardShortcut(.defaultAction).primaryButtonStyle()
                } else {
                    Button("Mit Kamera scannen") { Task { await startCamera() } }
                        .keyboardShortcut(.defaultAction).primaryButtonStyle()
                }
            }
        }
        .onChange(of: scanning) { _, now in model.cameraScanning = now }
        .onDisappear {
            importer.reset()
            model.cameraScanning = false
        }
        .confirmationDialog("Ein Screenshot enthält alle Schlüssel", isPresented: $confirmScreenshot, titleVisibility: .visible) {
            Button("Screenshot wählen") { Task { await ImportFlow.chooseImages(model: model) } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Kamera ist der bessere Weg, denn dann liegt der QR-Code nie als Datei auf dem Mac. Wenn du einen Screenshot nutzt, lösche ihn nach dem Import, auch aus dem Papierkorb und aus iCloud-Fotos.")
        }
    }

    private var sheetTitle: String {
        switch fileGuide {
        case .applePasswords: String(localized: "Aus Apple Passwörter importieren")
        case .otherApp: String(localized: "Aus anderer App importieren")
        case .microsoft: String(localized: "Aus Microsoft Authenticator umziehen")
        case nil: String(localized: "Aus Google Authenticator importieren")
        }
    }

    private var sheetSubtitle: String? {
        if scanning { return nil }
        switch fileGuide {
        case .applePasswords: return String(localized: "So holst du die Codes aus der App „Passwörter“ deines Macs oder iPhones:")
        case .otherApp: return String(localized: "Exportiere die Konten unverschlüsselt aus der anderen App und wähle die Datei hier aus.")
        case .microsoft: return String(localized: "Microsoft Authenticator gibt die Schlüssel nicht heraus, einen Export gibt es nicht. Deshalb richtest du jedes Konto einmal neu ein:")
        case nil: return String(localized: "So holst du deine Konten aus der Handy-App:")
        }
    }

    /// Shown wherever the file may contain passwords: only codes are read.
    private var passwordsNote: some View {
        Label("MacAuth liest aus der Datei nur die Codes. Passwörter in der Datei werden ignoriert und nicht gespeichert. Die Datei selbst enthält aber alle deine Passwörter: lösche sie nach dem Import, auch aus dem Papierkorb.",
              systemImage: "lock.shield")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var applePasswordsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                StepRow(number: 1, text: "Öffne auf dem Mac die App „Passwörter“.")
                StepRow(number: 2, text: "Wähle „Ablage“ > „Alle Passwörter in eine Datei exportieren“ und bestätige mit „Passwörter exportieren“.")
                StepRow(number: 3, text: "Speichere die CSV-Datei, zum Beispiel auf dem Schreibtisch, und wähle sie hier aus. Du kannst sie auch auf das Fenster ziehen.")
            }
            Text("Es werden nur Einträge übernommen, bei denen in „Passwörter“ ein Bestätigungscode eingerichtet ist. Alle anderen werden übersprungen.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            passwordsNote
        }
    }

    private var otherAppPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Aegis, 2FAS und Ente Auth (unverschlüsselte Exportdatei)", systemImage: "checkmark.circle")
                Label("Bitwarden (JSON, unverschlüsselt) und andOTP (unverschlüsselte Sicherung)", systemImage: "checkmark.circle")
                Label("Passwortmanager als CSV, etwa 1Password und Proton Pass", systemImage: "checkmark.circle")
                Label("Jede Textdatei mit otpauth-Links, ein Link je Zeile", systemImage: "checkmark.circle")
                Label("Microsoft Authenticator: Datenbank „PhoneFactor“ eines Android-Geräts mit Root-Zugriff", systemImage: "checkmark.circle")
            }
            .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("MacAuth erkennt das Format am Inhalt der Datei. Verschlüsselte Dateien werden abgelehnt, exportiere dann bitte unverschlüsselt. Eine Datei kannst du auch auf das Fenster ziehen.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            passwordsNote
        }
    }

    private var microsoftPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                StepRow(number: 1, text: "Melde dich am Mac beim Dienst an und öffne dort die Einstellungen für die Zwei-Faktor-Anmeldung.")
                StepRow(number: 2, text: "Richte dort die Authenticator-App neu ein oder füge eine weitere App hinzu. Der Dienst zeigt einen QR-Code.")
                StepRow(number: 3, text: "Nimm den QR-Code mit ⌃⇧⌘4 in die Zwischenablage auf und füge ihn hier mit ⌘V ein. Zeigt der Dienst nur einen Schlüssel, wähle „Schlüssel eingeben“.")
                StepRow(number: 4, text: "Bestätige die Einrichtung beim Dienst mit dem Code, den MacAuth anzeigt.")
            }
            Text("Das wiederholst du für jedes Konto. Im Hauptfenster genügt dafür ⌘V, den Assistenten brauchst du nicht jedes Mal.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Für Microsoft-Konten geht es hier entlang:").font(.callout.weight(.medium))
                VStack(spacing: 8) {
                    sourceButton(title: "Privates Konto", subtitle: "„Wie ich mich anmelde“, „App verwenden“, dann „Andere Authentifikator-App einrichten“",
                                 symbol: "person") { openURL(Self.microsoftPersonalURL) }
                    sourceButton(title: "Geschäfts- oder Schulkonto", subtitle: "Anmeldemethode hinzufügen, dann eine andere Authenticator-App wählen. Der Admin kann das sperren.",
                                 symbol: "building.2") { openURL(Self.microsoftWorkURL) }
                }
                Text("Die Seiten öffnen sich im Browser. Der Wortlaut bei Microsoft kann abweichen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Label("Lösche ein Konto erst dann aus Microsoft Authenticator, wenn der Code aus MacAuth beim Dienst funktioniert hat. Halte deine Wiederherstellungscodes bereit.",
                  systemImage: "exclamationmark.shield")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("Android-Gerät mit Root-Zugriff? Dann liest „Aus Datei importieren“ die Datenbank „PhoneFactor“ direkt ein.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var guidePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                StepRow(number: 1, text: "Öffne Google Authenticator auf dem Handy und tippe auf das Menü.")
                StepRow(number: 2, text: "Wähle „Konten übertragen“ und dann „Konten exportieren“. Wähle die Konten aus.")
                StepRow(number: 3, text: "Halte den QR-Code vor die Kamera deines Macs (empfohlen). Alternativ geht ein Screenshot, den du danach unbedingt wieder löschst.")
            }
            Text("Bei mehreren QR-Codes scannst du einen nach dem anderen. Ein Bild kannst du auch auf das Fenster ziehen oder mit ⌘V einfügen.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Du kommst nicht von Google Authenticator?").font(.callout.weight(.medium))
                HStack(spacing: 10) {
                    sourceButton(title: "Aus Apple Passwörter", subtitle: "Export der App „Passwörter“", symbol: "key") { fileGuide = .applePasswords }
                    sourceButton(title: "Aus anderer App (Datei)", subtitle: "Aegis, 2FAS, Ente, Bitwarden, andOTP, CSV", symbol: "doc.text") { fileGuide = .otherApp }
                }
                sourceButton(title: "Aus Microsoft Authenticator", subtitle: "Ohne Export: Konto für Konto neu einrichten, MacAuth führt dich durch", symbol: "arrow.triangle.swap") { fileGuide = .microsoft }
                Text("Eine MacAuth-Sicherung stellst du über „Backup wiederherstellen“ wieder her.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let problem = cameraProblem {
                VStack(alignment: .leading, spacing: 8) {
                    switch problem {
                    case .denied:
                        Label("MacAuth hat keinen Zugriff auf die Kamera. Du kannst ihn in den Systemeinstellungen erlauben oder stattdessen einen Screenshot wählen.", systemImage: "video.slash")
                        Button("Systemeinstellungen öffnen") { CameraAccess.openSystemSettings() }
                    default:
                        Label("An diesem Mac wurde keine Kamera gefunden. Wähle stattdessen einen Screenshot des QR-Codes.", systemImage: "video.slash")
                    }
                }
                .font(.callout)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func sourceButton(title: LocalizedStringKey, subtitle: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Color.accentColor).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var cameraPage: some View {
        CameraPreview { payloads in
            Task { @MainActor in
                // A scan that arrives after the app was locked (or the state changed) is ignored.
                guard let ticket = cameraTicket, model.isCurrent(ticket) else { return }
                if let session = importer.ingest(payloads, delivery: .camera, model: model) { model.sheet = .review(session) }
            }
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
        .overlay(alignment: .bottom) {
            Text("Halte den QR-Code ruhig ins Bild. Das Bild wird nicht gespeichert.")
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .floatingGlass(Capsule()).padding(12)
        }
        .overlay(alignment: .top) {
            if let progress = importer.progress {
                Text("\(progress.scanned) von \(progress.total) gescannt")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .floatingGlass(Capsule()).padding(12)
            }
        }
    }

    @ViewBuilder
    private var progressAndNotice: some View {
        if !scanning, let progress = importer.progress {
            HStack(spacing: 8) {
                ProgressView(value: Double(progress.scanned), total: Double(max(progress.total, 1))).frame(width: 120)
                Text("\(progress.scanned) von \(progress.total) gescannt").font(.callout.weight(.medium))
                if progress.scanned < progress.total {
                    Text("Weiter mit dem nächsten QR-Code.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        if let notice = importer.notice {
            Label(notice, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
        }
    }

    private func startCamera() async {
        var access = CameraAccess.current
        if access == .notDetermined { access = await CameraAccess.request() }
        if access == .authorized {
            cameraProblem = nil
            cameraTicket = model.ticket
            scanning = true
        } else {
            cameraProblem = access
        }
    }
}

private struct StepRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Color.accentColor, in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ReviewSheet: View {
    @Bindable var model: AppModel
    @Bindable var session: ImportSession
    @State private var saving = false
    @State private var confirmReplace = false
    @Environment(\.dismiss) private var dismiss

    private func runCommit() {
        saving = true
        Task {
            let ok = await model.commit(session)
            saving = false
            if ok { dismiss() }
        }
    }

    var body: some View {
        SheetScaffold(title: String(localized: "Konten prüfen"), subtitle: subtitle, width: 640, contentPadding: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Menu {
                        Button("Keine Gruppe") { session.setGroupForAll(nil) }
                        Divider()
                        ForEach(session.availableGroups) { group in
                            Button(group.name) { session.setGroupForAll(group.id) }
                        }
                    } label: {
                        Label("Alle in Gruppe …", systemImage: "folder")
                    }
                    .menuStyle(.button).fixedSize()
                    Spacer()
                    Button("Alle wählen") { session.setAll(included: true) }.buttonStyle(.link)
                    Button("Keine") { session.setAll(included: false) }.buttonStyle(.link)
                }
                .padding(.horizontal, 24)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach($session.rows) { $row in
                            ReviewRow(row: $row, groups: session.availableGroups)
                            Divider().padding(.leading, 66)
                        }
                    }
                }
                .frame(height: min(CGFloat(session.rows.count) * 52 + 4, 300))
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .top) { Divider() }
                .overlay(alignment: .bottom) { Divider() }
                if session.fileHasPasswords {
                    Label("Es werden nur die Codes importiert. Passwörter in der Datei werden ignoriert und nicht gespeichert. Lösche die Datei nach dem Import, sie enthält alle deine Passwörter.",
                          systemImage: "lock.shield")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, 24)
                }
                if session.mayBeIncomplete {
                    Label("Diese Datenbank wurde im laufenden Betrieb kopiert. Zuletzt hinzugefügte Konten stehen dann nur in der Begleitdatei „PhoneFactor-wal“ und fehlen hier. Vergleiche die Liste mit Microsoft Authenticator.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, 24)
                }
                if session.rowsWithoutCode > 0 {
                    Label("\(session.rowsWithoutCode) Einträge ohne Code übersprungen", systemImage: "minus.circle")
                        .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24)
                }
                if !session.skipped.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Übersprungen, weil MacAuth sie nicht unterstützt:", systemImage: "exclamationmark.triangle")
                            .font(.callout.weight(.medium)).foregroundStyle(.orange)
                        ForEach(Array(session.skipped.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                if session.replacesVault {
                    Label("Es entsteht ein neuer Tresor. Die bisherige Tresordatei bleibt erhalten.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 16)
        } footer: {
            Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
            Button {
                if session.replacesVault && !session.replaceConfirmed {
                    confirmReplace = true
                } else {
                    runCommit()
                }
            } label: {
                Text("\(session.selectedCount) Konten importieren")
            }
            .keyboardShortcut(.defaultAction).primaryButtonStyle()
            .disabled(session.selectedCount == 0 || saving)
        }
        .confirmationDialog("Neuen Tresor anlegen?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Abbrechen", role: .cancel) {}
            Button("Neuen Tresor anlegen") {
                session.replaceConfirmed = true
                runCommit()
            }
        } message: {
            Text("Der bisherige Tresor lässt sich gerade nicht öffnen. Seine Datei bleibt erhalten, du kannst sie später über „Frühere Fassung wiederherstellen“ zurückholen. Der neue Tresor enthält nur die ausgewählten Konten.")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let format = session.format { parts.append(String(localized: "Erkanntes Format: \(format.localizedName).")) }
        parts.append(String(localized: "\(session.rows.count) Konten gefunden. Es wird erst gespeichert, wenn du auf „Importieren“ klickst."))
        if session.duplicateCount > 0 {
            parts.append(String(localized: "\(session.duplicateCount) davon gibt es schon und sind abgewählt."))
        }
        return parts.joined(separator: " ")
    }
}

private struct ReviewRow: View {
    @Binding var row: ImportSession.Row
    let groups: [AccountGroup]

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Konto importieren", isOn: $row.include).toggleStyle(.checkbox).labelsHidden()
            MonogramTile(account: row.account, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.account.issuer.isEmpty ? row.account.name : row.account.issuer).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if !row.account.issuer.isEmpty {
                    Text(row.account.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if row.isDuplicate {
                Text("Schon vorhanden")
                    .font(.caption.weight(.medium)).foregroundStyle(.orange)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.14), in: Capsule())
            } else if row.account.kind == .hotp {
                Text("HOTP").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Color.primary.opacity(0.07), in: Capsule())
            }
            Picker("Gruppe", selection: $row.groupID) {
                Text("Keine Gruppe").tag(UUID?.none)
                ForEach(groups) { group in Text(group.name).tag(UUID?.some(group.id)) }
            }
            .labelsHidden().frame(width: 140)
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
        .opacity(row.include ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }
}
