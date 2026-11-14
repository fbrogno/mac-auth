import AuthCore
import SwiftUI
import UniformTypeIdentifiers

/// Sensitive actions start with a fresh Touch ID / password check, then open their sheet.
@MainActor
enum BackupFlow {
    static func startExport(_ model: AppModel) async {
        guard model.phase == .unlocked, !model.accounts.isEmpty else { return }
        let ticket = model.ticket
        if await model.authenticateForExport(reason: String(localized: "Backup exportieren")), model.isCurrent(ticket) { model.sheet = .exportBackup }
    }

    /// Export in a foreign format (plain text). Order: fresh authentication here, then the sheet (target, warning), then
    /// the save panel and the write inside the sheet. A dialog that answers after the app was locked is dropped.
    static func startPlainExport(_ model: AppModel) async {
        guard model.phase == .unlocked, !model.accounts.isEmpty else { return }
        let ticket = model.ticket
        if await model.authenticateForExport(reason: String(localized: "Konten unverschlüsselt exportieren")), model.isCurrent(ticket) {
            model.sheet = .exportPlain
        }
    }

    static func startTransfer(_ model: AppModel, ids: Set<UUID>? = nil) async {
        guard model.phase == .unlocked, !model.accounts.isEmpty else { return }
        let ticket = model.ticket
        if await model.authenticateForExport(reason: String(localized: "QR-Codes für die Übertragung anzeigen")), model.isCurrent(ticket) {
            model.sheet = .transfer(ids)
        }
    }
}

/// Export for another app: three plain-text targets. Stages: choose the target, confirm the warning, (save panel, write),
/// confirmation. The file content is built only after the warning was confirmed and is never kept in the view state.
struct PlainExportSheet: View {
    enum Target: String, CaseIterable, Identifiable {
        case links, aegis, apple
        var id: String { rawValue }
        var title: String {
            switch self {
            case .links: String(localized: "Link-Liste (otpauth)")
            case .aegis: String(localized: "Aegis (JSON)")
            case .apple: String(localized: "Apple Passwörter (CSV)")
            }
        }
        var detail: String {
            switch self {
            case .links: String(localized: "Eine Textdatei mit einem otpauth-Link je Zeile. Viele Apps lesen sie, zum Beispiel Ente Auth.")
            case .aegis: String(localized: "Ein unverschlüsselter Aegis-Tresor mit Gruppen, Favoriten und Notizen.")
            case .apple: String(localized: "Eine CSV-Datei für die App „Passwörter“. Nur zeitbasierte Codes (TOTP), Zähler-Codes (HOTP) bleiben zurück.")
            }
        }
        var symbol: String {
            switch self {
            case .links: "link"
            case .aegis: "shield.lefthalf.filled"
            case .apple: "key"
            }
        }
        var type: UTType {
            switch self {
            case .links: .plainText
            case .aegis: .json
            case .apple: .commaSeparatedText
            }
        }
        var fileName: String {
            let stamp = Date().formatted(.iso8601.year().month().day())
            switch self {
            case .links: return "MacAuth-Konten-\(stamp).txt"
            case .aegis: return "MacAuth-Aegis-\(stamp).json"
            case .apple: return "MacAuth-Passwoerter-\(stamp).csv"
            }
        }
    }

    enum Stage { case choose, warning, done }

    struct Outcome {
        var count: Int
        var skipped: [ExportSkippedEntry]
        var fileName: String
    }

    @Bindable var model: AppModel
    @State private var stage: Stage
    @State private var target: Target
    @State private var busy = false
    @State private var outcome: Outcome?
    @State private var errorText: String?
    @State private var ticket: Ticket
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, stage: Stage = .choose, target: Target = .links, previewOutcome: Outcome? = nil) {
        self.model = model
        _stage = State(initialValue: stage)
        _target = State(initialValue: target)
        _outcome = State(initialValue: previewOutcome)
        _ticket = State(initialValue: model.ticket)
    }

    var body: some View {
        SheetScaffold(title: title, subtitle: subtitle, width: 520) {
            switch stage {
            case .choose: choosePage
            case .warning: warningPage
            case .done: donePage
            }
        } footer: {
            switch stage {
            case .choose:
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Weiter") { stage = .warning }.keyboardShortcut(.defaultAction).primaryButtonStyle()
            case .warning:
                if busy { ProgressView().controlSize(.small) }
                Button("Zurück") { stage = .choose }.disabled(busy)
                Spacer()
                // Return = cancel; the export button has no shortcut. Esc closes the sheet as well.
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.defaultAction).primaryButtonStyle()
                Button("Trotzdem exportieren …") { Task { await export() } }.tint(.red).disabled(busy)
            case .done:
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction).primaryButtonStyle()
            }
        }
    }

    private var title: String {
        switch stage {
        case .choose: String(localized: "Für andere App exportieren")
        case .warning: String(localized: "Diese Datei ist nicht geschützt")
        case .done: String(localized: "Datei gespeichert")
        }
    }

    private var subtitle: String? {
        switch stage {
        case .choose: String(localized: "Unverschlüsselt. Wähle das Ziel.")
        case .warning: String(localized: "Ziel: \(target.title)")
        case .done: nil
        }
    }

    private var choosePage: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Target.allCases) { option in
                Button { target = option } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: target == option ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(target == option ? Color.accentColor : .secondary).font(.system(size: 16)).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Label(option.title, systemImage: option.symbol).font(.system(size: 13, weight: .semibold))
                            Text(option.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(target == option ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(target == option ? .isSelected : [])
            }
            Label("Für die Sicherung deiner Konten ist das verschlüsselte Backup der bessere Weg. Diese Dateien sind nur zum Umziehen in eine andere App gedacht.", systemImage: "lock")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var warningPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Die Datei enthält die Schlüssel aller deiner Konten im Klartext.").font(.system(size: 13, weight: .semibold))
                    Text("Wer die Datei hat, kann alle Codes selbst erzeugen, ohne dein Handy und ohne MacAuth.")
                    Text("Importiere sie sofort in die andere App und lösche sie danach, auch aus dem Papierkorb. Lege sie nie in einem Cloud-Ordner ab (iCloud Drive, Dropbox, OneDrive u. a.).")
                }
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 20))
            }
            .font(.callout)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("Die Datei wird nur für dich lesbar angelegt (Zugriffsrechte 600, ohne zusätzliche Zugriffsregeln). Auf Laufwerken ohne Unix-Rechte, zum Beispiel exFAT oder manche Netzlaufwerke, gilt das nicht. In die Zwischenablage oder ein Protokoll wird nichts geschrieben.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let errorText { Text(errorText).font(.callout).foregroundStyle(.red) }
        }
    }

    private var donePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let outcome {
                Label("\(outcome.count) Konten wurden in „\(outcome.fileName)“ geschrieben.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
                if !outcome.skipped.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("\(outcome.skipped.count) Konten konnten nicht exportiert werden:", systemImage: "exclamationmark.triangle")
                            .font(.callout.weight(.medium)).foregroundStyle(.orange)
                        ForEach(Array(outcome.skipped.enumerated()), id: \.offset) { _, entry in
                            Text("\(entry.label): \(entry.reason.localizedText)").font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Label("Importiere die Datei jetzt und lösche sie danach, auch aus dem Papierkorb und aus iCloud Drive. Sie enthält alle Schlüssel im Klartext.", systemImage: "trash")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func export() async {
        // The data is built only now, from the state at this moment, and only while the app is still in the state
        // the authentication was done in. It lives in local variables only.
        guard model.isCurrent(ticket), !busy else { return }
        let chosen = target
        // Cheap check without building any export data: is there at least one account this format can hold?
        let usable = model.accounts.filter { (try? $0.validate()) != nil && (chosen != .apple || $0.kind == .totp) }
        guard !usable.isEmpty else {
            errorText = String(localized: "Kein Konto lässt sich in diesem Format ablegen. Wähle ein anderes Ziel.")
            return
        }
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            // The panel comes first. The data is built only after a location was chosen and only if the app is still
            // in the state the authentication was done in; it lives in local variables only. A lock closes the panel.
            guard let url = await FilePanels.savePlainExport(suggestedName: chosen.fileName, type: chosen.type), model.isCurrent(ticket) else { return }
            let vault = model.currentVault
            let result: ExportResult
            switch chosen {
            case .links: result = AccountExporter.otpauthList(vault.accounts)
            case .aegis: result = try AccountExporter.aegisJSON(vault.accounts, groups: vault.groups)
            case .apple: result = AccountExporter.applePasswordsCSV(vault.accounts)
            }
            guard result.exportedCount > 0 else {
                errorText = String(localized: "Kein Konto lässt sich in diesem Format ablegen. Wähle ein anderes Ziel.")
                return
            }
            try PrivateFile.write(result.data, to: url)
            outcome = Outcome(count: result.exportedCount, skipped: result.skipped, fileName: url.lastPathComponent)
            stage = .done
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }
}

enum PasswordStrength {
    /// 0 too short, 1 okay, 2 good, 3 strong.
    static func level(_ password: String) -> Int {
        let length = password.count
        guard length >= BackupFile.minimumPasswordLength else { return 0 }
        let classes = [password.contains { $0.isLowercase }, password.contains { $0.isUppercase },
                       password.contains { $0.isNumber }, password.contains { !$0.isLetter && !$0.isNumber }].filter { $0 }.count
        return 1 + (length >= 14 ? 1 : 0) + (classes >= 3 && length >= 12 ? 1 : 0)
    }
}

struct ExportBackupSheet: View {
    @Bindable var model: AppModel
    @State private var password = ""
    @State private var repeated = ""
    @State private var busy = false
    @State private var done = false
    @State private var incomplete = false
    @State private var errorText: String?
    @State private var ticket: Ticket
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, previewPassword: String? = nil) {
        self.model = model
        _ticket = State(initialValue: model.ticket)
        _password = State(initialValue: previewPassword ?? "")
        _repeated = State(initialValue: previewPassword ?? "")
    }

    private var level: Int { PasswordStrength.level(password) }
    private var mismatch: Bool { !repeated.isEmpty && repeated != password }
    private var canExport: Bool { level > 0 && password == repeated && !busy }

    var body: some View {
        SheetScaffold(title: String(localized: "Backup exportieren"),
                      subtitle: String(localized: "Alle Konten und Gruppen, verschlüsselt mit einem Passwort deiner Wahl.")) {
            if done {
                VStack(spacing: 8) {
                    Label("Das Backup wurde gespeichert.", systemImage: "checkmark.circle.fill")
                        .font(.title3).foregroundStyle(.green)
                    if incomplete {
                        Text("Während des Speicherns haben sich Konten geändert. Das Backup enthält den Stand vom Start des Exports. Exportiere noch einmal, damit die Erinnerung zurückgesetzt wird.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 12)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    SecureField("Passwort", text: $password).textFieldStyle(.roundedBorder)
                    SecureField("Passwort wiederholen", text: $repeated).textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        StrengthBar(level: level, active: !password.isEmpty)
                        Text(strengthText).font(.callout).foregroundStyle(strengthColor)
                    }
                    if mismatch {
                        Label("Die Passwörter stimmen nicht überein.", systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Text("Mindestens \(BackupFile.minimumPasswordLength) Zeichen. Ein Passwort aus einem Passwortmanager oder mehrere zufällige Wörter sind am besten.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Label("Ohne dieses Passwort lässt sich das Backup nicht öffnen. Es gibt keine Möglichkeit, es zurückzusetzen.", systemImage: "key.slash")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let errorText { Text(errorText).font(.callout).foregroundStyle(.red) }
                }
            }
        } footer: {
            if done {
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction).primaryButtonStyle()
            } else {
                if busy { ProgressView().controlSize(.small) }
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Exportieren …") { Task { await export() } }
                    .keyboardShortcut(.defaultAction).primaryButtonStyle().disabled(!canExport)
            }
        }
    }

    private var strengthText: String {
        if password.isEmpty { return String(localized: "Noch kein Passwort") }
        switch level {
        case 0: return String(localized: "Zu kurz")
        case 1: return String(localized: "Okay")
        case 2: return String(localized: "Gut")
        default: return String(localized: "Stark")
        }
    }

    private var strengthColor: Color {
        if password.isEmpty { return .secondary }
        return level == 0 ? .orange : level == 1 ? .secondary : .green
    }

    private func export() async {
        // The exported state is fixed here; an empty vault never produces a backup.
        let data = model.currentVault
        guard model.isCurrent(ticket), !data.accounts.isEmpty else { return }
        busy = true
        errorText = nil
        defer { busy = false }
        let secret = password
        do {
            // Panel first; the (slow) encryption starts only after a location was chosen and the app is still in the same state.
            let stamp = Date().formatted(.iso8601.year().month().day())
            guard let url = await FilePanels.saveBackup(suggestedName: "MacAuth-Backup-\(stamp).\(BackupFile.fileExtension)"),
                  model.isCurrent(ticket) else { return }
            let file = try await Task.detached(priority: .userInitiated) { try BackupFile.encrypt(data, password: secret) }.value
            guard model.isCurrent(ticket) else { return }
            try file.write(to: url, options: .atomic)
            incomplete = !model.backupWritten(data)
            password = ""
            repeated = ""
            done = true
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }
}

struct StrengthBar: View {
    let level: Int
    let active: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(active && index < max(level, active ? 1 : 0) ? (level == 0 ? Color.orange : Color.green) : Color.primary.opacity(0.12))
                    .frame(width: 34, height: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

struct RestoreSheet: View {
    @Bindable var model: AppModel
    let replace: Bool
    @State private var fileName: String?
    @State private var fileData: Data?
    @State private var password = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var ticket: Ticket
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, preset: BackupPreset?, replace: Bool) {
        self.model = model
        self.replace = replace
        _fileName = State(initialValue: preset?.name)
        _fileData = State(initialValue: preset?.data)
        _ticket = State(initialValue: model.ticket)
    }

    var body: some View {
        SheetScaffold(title: String(localized: "Backup wiederherstellen"),
                      subtitle: String(localized: "Wähle die Backup-Datei und gib das Passwort ein, mit dem du sie gesichert hast.")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "doc.badge.gearshape").foregroundStyle(.secondary)
                    Text(fileName ?? String(localized: "Keine Datei gewählt"))
                        .foregroundStyle(fileName == nil ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Datei wählen …") { Task { await choose() } }
                }
                .padding(10).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                SecureField("Passwort", text: $password).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await restore() } }
                if replace {
                    Label("Es entsteht ein neuer Tresor aus dem Backup. Die bisherige Tresordatei bleibt erhalten.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Du siehst die Konten vorher durch. Es wird nichts überschrieben.", systemImage: "eye")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let errorText { Text(errorText).font(.callout).foregroundStyle(.red) }
            }
        } footer: {
            if busy { ProgressView().controlSize(.small) }
            Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Weiter") { Task { await restore() } }
                .keyboardShortcut(.defaultAction).primaryButtonStyle().disabled(fileData == nil || password.isEmpty || busy)
        }
    }

    private func choose() async {
        guard let url = await FilePanels.openBackup(), model.isCurrent(ticket) else { return }
        let loaded: Data? = await Task.detached(priority: .userInitiated) {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            return try? Data(contentsOf: url)
        }.value
        guard model.isCurrent(ticket) else { return }
        if let loaded {
            fileData = loaded
            fileName = url.lastPathComponent
            errorText = nil
        } else {
            errorText = ErrorText.message(for: BackupError.ioFailure(""))
        }
    }

    private func restore() async {
        guard let file = fileData, !password.isEmpty, !busy, model.isCurrent(ticket) else { return }
        busy = true
        errorText = nil
        defer { busy = false }
        let secret = password
        do {
            let data = try await Task.detached(priority: .userInitiated) { try BackupFile.decrypt(file, password: secret) }.value
            guard model.isCurrent(ticket) else { return }
            password = ""
            let session = model.makeSession(source: .backup, delivery: .backup, accounts: data.accounts, groups: data.groups,
                                            intent: replace ? .replaceVault : nil)
            model.sheet = .review(session)
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }
}

struct TransferSheet: View {
    @Bindable var model: AppModel
    let preselected: Set<UUID>?

    enum Format: Hashable { case google, single }
    struct Page: Identifiable {
        let id = UUID()
        let uri: String
        let caption: String
    }

    @State private var format: Format = .google
    @State private var scope: UUID?   // nil = all accounts
    @State private var pages: [Page] = []
    @State private var index = 0
    @State private var problem: String?
    @State private var unsupported: [String] = []
    @State private var image: NSImage?
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, preselected: Set<UUID>?) {
        self.model = model
        self.preselected = preselected
        _format = State(initialValue: (preselected?.count ?? 0) == 1 ? .single : .google)
    }

    private var selectedAccounts: [Account] {
        let all = model.accounts.sorted { $0.sortIndex < $1.sortIndex }
        if let preselected { return all.filter { preselected.contains($0.id) } }
        if let scope { return all.filter { $0.groupID == scope } }
        return all
    }

    var body: some View {
        SheetScaffold(title: String(localized: "Auf Handy übertragen"),
                      subtitle: String(localized: "Scanne die QR-Codes mit Google Authenticator: Menü, „Konten übertragen“, „Konten importieren“."), width: 500) {
            VStack(spacing: 14) {
                if preselected == nil || (preselected?.count ?? 0) > 1 {
                    HStack {
                        Picker("Format", selection: $format) {
                            Text("Google-Format").tag(Format.google)
                            Text("Ein QR-Code je Konto").tag(Format.single)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        if preselected == nil, model.groups.count > 0 {
                            Picker("Konten", selection: $scope) {
                                Text("Alle Konten").tag(UUID?.none)
                                ForEach(model.groups) { group in Text(group.name).tag(UUID?.some(group.id)) }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                }
                if !unsupported.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Nicht im Google-Format übertragbar:", systemImage: "exclamationmark.triangle")
                            .font(.callout.weight(.medium)).foregroundStyle(.orange)
                        Text(unsupported.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                        Text("Für diese Konten folgt je ein eigener QR-Code am Ende. Er enthält die genauen Einstellungen, ob deine Handy-App ihn liest, hängt von der App ab.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let image {
                    Image(nsImage: image).resizable().interpolation(.none).frame(width: 260, height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                        .accessibilityLabel(Text("QR-Code zur Übertragung"))
                } else {
                    ProgressView().frame(width: 260, height: 260)
                }
                if pages.count > 1 || format == .single {
                    HStack(spacing: 14) {
                        Button { index = max(0, index - 1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                        VStack(spacing: 1) {
                            Text("QR-Code \(index + 1) von \(pages.count)").font(.callout.weight(.medium))
                            if let caption = pages.indices.contains(index) ? pages[index].caption : nil, !caption.isEmpty {
                                Text(caption).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(minWidth: 200)
                        Button { index = min(pages.count - 1, index + 1) } label: { Image(systemName: "chevron.right") }.disabled(index >= pages.count - 1)
                    }
                }
                Label("Diese QR-Codes enthalten deine Geheimnisse. Zeige sie niemandem und schließe das Fenster danach.", systemImage: "eye.slash")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Button("Schließen") { dismiss() }.keyboardShortcut(.defaultAction).primaryButtonStyle()
        }
        .onAppear(perform: rebuild)
        .onChange(of: format) { rebuild() }
        .onChange(of: scope) { rebuild() }
        .onChange(of: index) { renderImage() }
        .task {
            // The codes disappear by themselves after two minutes.
            try? await Task.sleep(for: .seconds(120))
            dismiss()
        }
    }

    private func rebuild() {
        index = 0
        problem = nil
        unsupported = []
        let accounts = selectedAccounts
        guard !accounts.isEmpty else {
            pages = []
            image = nil
            problem = String(localized: "In dieser Auswahl gibt es keine Konten.")
            return
        }
        switch format {
        case .google:
            // Accounts the Google format cannot hold (other period, 7 digits, ...) are split off up front and get a
            // single otpauth code each, so nothing is exported with wrong settings.
            var fitting: [Account] = []
            var rest: [Account] = []
            for account in accounts {
                if (try? MigrationCodec.uris(for: [account])) != nil { fitting.append(account) } else { rest.append(account) }
            }
            unsupported = rest.map(\.displayLabel)
            var built: [Page] = []
            if !fitting.isEmpty {
                do {
                    let uris = try MigrationCodec.uris(for: fitting)
                    built = uris.map { Page(uri: $0, caption: String(localized: "bis zu \(MigrationCodec.maxAccountsPerCode) Konten je Code")) }
                } catch {
                    pages = []
                    problem = ErrorText.message(for: error)
                    return
                }
            }
            built += rest.map { Page(uri: OTPAuthURI.string(for: $0), caption: String(localized: "Einzel-QR-Code: \($0.displayLabel)")) }
            pages = built
        case .single:
            pages = accounts.map { Page(uri: OTPAuthURI.string(for: $0), caption: $0.displayLabel) }
        }
        renderImage()
    }

    private func renderImage() {
        guard pages.indices.contains(index) else { image = nil; return }
        image = QRGenerator.image(for: pages[index].uri, size: 520)
    }
}

/// Lists vault files that can be brought back when the current vault cannot be opened. Nothing here deletes anything.
struct RescueSheet: View {
    @Bindable var model: AppModel
    @State private var entries: [RescueEntry] = []
    @State private var loaded = false
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: String(localized: "Frühere Fassung wiederherstellen"),
                      subtitle: String(localized: "Diese Tresordateien liegen noch auf diesem Mac. Nichts davon wurde gelöscht."), width: 540) {
            VStack(alignment: .leading, spacing: 10) {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                } else if entries.isEmpty {
                    Label("Es gibt keine ältere Fassung. Du kannst es erneut versuchen oder ein Backup einspielen.", systemImage: "tray")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        HStack(spacing: 12) {
                            Image(systemName: entry.isPrevious ? "clock.arrow.circlepath" : "archivebox").foregroundStyle(.secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.isPrevious ? String(localized: "Vorherige Fassung") : String(localized: "Ersetzter Tresor"))
                                    .font(.system(size: 13, weight: .semibold))
                                Text(detail(entry)).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Wiederherstellen") { Task { await restore(entry) } }.disabled(busy)
                        }
                        .padding(10).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    Text("Danach wirst du wie gewohnt zum Entsperren gefragt. Der Tresor, der sich nicht öffnen ließ, wird dabei zur Seite gelegt, nicht gelöscht.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            if busy { ProgressView().controlSize(.small) }
            Button("Schließen") { dismiss() }.keyboardShortcut(.defaultAction).primaryButtonStyle()
        }
        .task {
            entries = await model.rescueEntries()
            loaded = true
        }
    }

    private func detail(_ entry: RescueEntry) -> String {
        var parts: [String] = []
        if entry.date != .distantPast { parts.append(entry.date.formatted(date: .abbreviated, time: .shortened)) }
        switch entry.protector {
        case "secure-enclave": parts.append(String(localized: "Secure Enclave"))
        case "keychain": parts.append(String(localized: "Schlüsselbund"))
        default: break
        }
        return parts.joined(separator: " · ")
    }

    private func restore(_ entry: RescueEntry) async {
        busy = true
        defer { busy = false }
        if await model.restore(entry) { dismiss() }
    }
}
