import AuthCore
import SwiftUI

/// Sensitive actions start with a fresh Touch ID / password check, then open their sheet.
@MainActor
enum BackupFlow {
    static func startExport(_ model: AppModel) async {
        guard model.phase == .unlocked, !model.accounts.isEmpty else { return }
        if await model.authenticate(reason: String(localized: "Backup exportieren")) { model.sheet = .exportBackup }
    }

    static func startTransfer(_ model: AppModel) async {
        guard model.phase == .unlocked, !model.accounts.isEmpty else { return }
        if await model.authenticate(reason: String(localized: "QR-Codes für die Übertragung anzeigen")) { model.sheet = .transfer(nil) }
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
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, previewPassword: String? = nil) {
        self.model = model
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
                Label("Das Backup wurde gespeichert.", systemImage: "checkmark.circle.fill")
                    .font(.title3).foregroundStyle(.green).padding(.vertical, 12)
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
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            } else {
                if busy { ProgressView().controlSize(.small) }
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Exportieren …") { Task { await export() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!canExport)
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
        busy = true
        errorText = nil
        defer { busy = false }
        let data = VaultData(accounts: model.accounts, groups: model.groups)
        let secret = password
        do {
            let file = try await Task.detached(priority: .userInitiated) { try BackupFile.encrypt(data, password: secret) }.value
            let stamp = Date().formatted(.iso8601.year().month().day())
            guard let url = await FilePanels.saveBackup(suggestedName: "MacAuth-Backup-\(stamp).\(BackupFile.fileExtension)") else { return }
            try file.write(to: url, options: .atomic)
            model.settings.lastBackupExport = Date().timeIntervalSince1970
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
    @State private var fileURL: URL?
    @State private var password = ""
    @State private var busy = false
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: String(localized: "Backup wiederherstellen"),
                      subtitle: String(localized: "Wähle die Backup-Datei und gib das Passwort ein, mit dem du sie gesichert hast.")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "doc.badge.gearshape").foregroundStyle(.secondary)
                    Text(fileURL?.lastPathComponent ?? String(localized: "Keine Datei gewählt"))
                        .foregroundStyle(fileURL == nil ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Datei wählen …") { Task { fileURL = await FilePanels.openBackup() ?? fileURL; errorText = nil } }
                }
                .padding(10).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                SecureField("Passwort", text: $password).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await restore() } }
                if model.phase == .locked {
                    Label("Der vorhandene, nicht mehr nutzbare Tresor wird ersetzt.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout).foregroundStyle(.secondary)
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
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(fileURL == nil || password.isEmpty || busy)
        }
    }

    private func restore() async {
        guard let url = fileURL, !password.isEmpty, !busy else { return }
        busy = true
        errorText = nil
        defer { busy = false }
        let secret = password
        do {
            let data = try await Task.detached(priority: .userInitiated) { () -> VaultData in
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                let file: Data
                do { file = try Data(contentsOf: url) } catch { throw BackupError.ioFailure("") }
                return try BackupFile.decrypt(file, password: secret)
            }.value
            password = ""
            let session = model.makeSession(source: .backup, accounts: data.accounts, backup: data)
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
            Button("Schließen") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
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
        let accounts = selectedAccounts
        guard !accounts.isEmpty else {
            pages = []
            image = nil
            problem = String(localized: "In dieser Auswahl gibt es keine Konten.")
            return
        }
        switch format {
        case .google:
            do {
                let uris = try MigrationCodec.uris(for: accounts)
                pages = uris.enumerated().map { Page(uri: $0.element, caption: String(localized: "bis zu \(MigrationCodec.maxAccountsPerCode) Konten je Code")) }
            } catch {
                pages = []
                problem = ErrorText.message(for: error)
            }
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
