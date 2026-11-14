import AuthCore
import SwiftUI

struct AccountFormSheet: View {
    @Bindable var model: AppModel
    let editing: Account?

    @State private var issuer = ""
    @State private var name = ""
    @State private var secretText = ""
    @State private var showSecret = false
    @State private var kind: OTPKind = .totp
    @State private var algorithm: OTPAlgorithm = .sha1
    @State private var digits = 6
    @State private var period = OTP.defaultPeriod
    @State private var counter = 0
    @State private var groupID: UUID?
    @State private var note = ""
    @State private var showAdvanced = false
    @State private var saving = false
    @State private var ticket: Ticket
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, editing: Account?, prefill: Account? = nil) {
        _ticket = State(initialValue: model.ticket)
        self.model = model
        self.editing = editing
        if let p = prefill {
            _issuer = State(initialValue: p.issuer)
            _name = State(initialValue: p.name)
            _secretText = State(initialValue: Base32.encode(p.secret))
        }
        if let a = editing {
            _issuer = State(initialValue: a.issuer)
            _name = State(initialValue: a.name)
            _kind = State(initialValue: a.kind)
            _algorithm = State(initialValue: a.algorithm)
            _digits = State(initialValue: a.digits)
            _period = State(initialValue: a.period)
            _counter = State(initialValue: Int(clamping: a.counter))
            _groupID = State(initialValue: a.groupID)
            _note = State(initialValue: a.note)
        } else {
            var preset: UUID?
            if case .group(let id) = model.sidebar { preset = id }
            else if let id = UUID(uuidString: model.settings.defaultGroupID), model.groups.contains(where: { $0.id == id }) { preset = id }
            _groupID = State(initialValue: preset)
        }
    }

    private enum KeyStatus: Equatable {
        case empty, valid, invalid(String)
    }

    private var keyStatus: KeyStatus {
        let trimmed = secretText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        do {
            let data = try Base32.decode(trimmed)
            return data.isEmpty ? .invalid(ErrorText.message(for: OTPError.emptySecret)) : .valid
        } catch {
            return .invalid(ErrorText.message(for: error))
        }
    }

    private var candidate: Account? {
        guard editing != nil || keyStatus == .valid else { return nil }
        guard let secret = editing?.secret ?? (try? Base32.decode(secretText)) else { return nil }
        return Account(issuer: issuer.trimmingCharacters(in: .whitespaces), name: name.trimmingCharacters(in: .whitespaces), secret: secret,
                       algorithm: algorithm, digits: digits, period: period, kind: kind, counter: UInt64(max(counter, 0)),
                       groupID: groupID, note: note)
    }

    private var isDuplicate: Bool {
        guard editing == nil, let candidate else { return false }
        return model.accounts.contains { $0.isDuplicate(of: candidate) }
    }

    private var canSave: Bool {
        let hasLabel = !name.trimmingCharacters(in: .whitespaces).isEmpty || !issuer.trimmingCharacters(in: .whitespaces).isEmpty
        return hasLabel && candidate != nil && !isDuplicate && !saving
    }

    var body: some View {
        SheetScaffold(title: editing == nil ? String(localized: "Konto hinzufügen") : String(localized: "Konto bearbeiten"), width: 520, contentPadding: false) {
            Form {
                Section {
                    TextField("Aussteller", text: $issuer, prompt: Text("z. B. GitHub"))
                    TextField("Konto", text: $name, prompt: Text("z. B. name@firma.de"))
                }
                if let editing {
                    Section {
                        LabeledContent("Setup-Schlüssel") {
                            Text("••••••••••••").foregroundStyle(.secondary)
                        }
                        Text("Der Schlüssel bleibt verborgen und lässt sich nicht ändern. Für einen anderen Schlüssel lege ein neues Konto an.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .id(editing.id)
                } else {
                    Section {
                        HStack {
                            Group {
                                if showSecret {
                                    TextField("Setup-Schlüssel", text: $secretText, prompt: Text("Schlüssel oder otpauth-Link"))
                                } else {
                                    SecureField("Setup-Schlüssel", text: $secretText, prompt: Text("Schlüssel oder otpauth-Link"))
                                }
                            }
                            .autocorrectionDisabled()
                            Button { showSecret.toggle() } label: { Image(systemName: showSecret ? "eye.slash" : "eye") }
                                .buttonStyle(.borderless)
                                .help(Text(showSecret ? String(localized: "Schlüssel verbergen") : String(localized: "Schlüssel anzeigen")))
                        }
                        switch keyStatus {
                        case .empty:
                            Text("Füge den Schlüssel aus dem QR-Code-Fenster der Website ein. Einen otpauth-Link kannst du direkt hier einfügen.")
                                .font(.callout).foregroundStyle(.secondary)
                        case .valid:
                            Label("Gültiger Schlüssel", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                        case .invalid(let message):
                            Label(message, systemImage: "exclamationmark.circle.fill").font(.callout).foregroundStyle(.orange)
                        }
                        if isDuplicate {
                            Label("Dieses Konto gibt es schon.", systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    Picker("Gruppe", selection: $groupID) {
                        Text("Keine Gruppe").tag(UUID?.none)
                        ForEach(model.groups) { group in Text(group.name).tag(UUID?.some(group.id)) }
                    }
                    TextField("Notiz", text: $note, prompt: Text("optional"), axis: .vertical).lineLimit(1...3)
                }
                if editing == nil {
                    Section {
                        DisclosureGroup("Erweitert", isExpanded: $showAdvanced) {
                            Picker("Typ", selection: $kind) {
                                Text("Zeitbasiert (TOTP)").tag(OTPKind.totp)
                                Text("Zählerbasiert (HOTP)").tag(OTPKind.hotp)
                            }
                            Picker("Algorithmus", selection: $algorithm) {
                                Text("SHA-1").tag(OTPAlgorithm.sha1)
                                Text("SHA-256").tag(OTPAlgorithm.sha256)
                                Text("SHA-512").tag(OTPAlgorithm.sha512)
                            }
                            Picker("Stellen", selection: $digits) {
                                Text("6").tag(6)
                                Text("7").tag(7)
                                Text("8").tag(8)
                            }
                            .pickerStyle(.segmented)
                            if kind == .totp {
                                Stepper("Intervall: \(period) Sekunden", value: $period, in: 15...120, step: 5)
                            } else {
                                Stepper("Zähler: \(counter)", value: $counter, in: 0...1_000_000)
                            }
                        }
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: showAdvanced ? 520 : 390)
        } footer: {
            Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Sichern") { Task { await save() } }
                .keyboardShortcut(.defaultAction).primaryButtonStyle().disabled(!canSave)
        }
        .onChange(of: secretText) { adoptLinkIfPasted() }
    }

    /// A pasted otpauth link fills the whole form.
    private func adoptLinkIfPasted() {
        guard OTPAuthURI.isOTPAuthURI(secretText) else { return }
        do {
            let a = try OTPAuthURI.parse(secretText)
            issuer = a.issuer; name = a.name; kind = a.kind; algorithm = a.algorithm; digits = a.digits
            period = a.period; counter = Int(clamping: a.counter)
            secretText = Base32.encode(a.secret)
            errorText = nil
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }

    private func save() async {
        guard let account = candidate else { return }
        saving = true
        defer { saving = false }
        do {
            try account.validate()
        } catch {
            errorText = ErrorText.message(for: error)
            return
        }
        if let editing {
            model.update(editing.id, with: AccountEdit(issuer: issuer.trimmingCharacters(in: .whitespaces),
                                                       name: name.trimmingCharacters(in: .whitespaces), groupID: groupID, note: note))
            dismiss()
        } else if await model.add(account, ticket: ticket) {
            dismiss()
        }
    }
}
