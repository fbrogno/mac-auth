import AuthCore
import SwiftUI

struct ImportSheet: View {
    @Bindable var model: AppModel
    @State private var scanning = false
    @State private var cameraProblem: CameraAccess?
    @State private var cameraTicket: Ticket?
    @State private var confirmScreenshot = false
    @Environment(\.dismiss) private var dismiss

    private var importer: ImportCoordinator { model.importer }

    var body: some View {
        SheetScaffold(title: String(localized: "Aus Google Authenticator importieren"),
                      subtitle: scanning ? nil : String(localized: "So holst du deine Konten aus der Handy-App:"), width: 540) {
            VStack(alignment: .leading, spacing: 14) {
                if scanning { cameraPage } else { guidePage }
                progressAndNotice
            }
        } footer: {
            if scanning {
                Button("Zurück") { scanning = false }
            } else {
                Button("Screenshot wählen …") { confirmScreenshot = true }
            }
            Spacer()
            Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
            if !scanning {
                Button("Mit Kamera scannen") { Task { await startCamera() } }
                    .keyboardShortcut(.defaultAction).primaryButtonStyle()
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

    private var guidePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                StepRow(number: 1, text: "Öffne Google Authenticator auf dem Handy und tippe auf das Menü.")
                StepRow(number: 2, text: "Wähle „Konten übertragen“ und dann „Konten exportieren“. Wähle die Konten aus.")
                StepRow(number: 3, text: "Halte den QR-Code vor die Kamera deines Macs (empfohlen). Alternativ geht ein Screenshot, den du danach unbedingt wieder löschst.")
            }
            Text("Bei mehreren QR-Codes scannst du einen nach dem anderen. Ein Bild kannst du auch auf das Fenster ziehen oder mit ⌘V einfügen.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Du hast eine Exportdatei von Aegis, 2FAS, Ente Auth oder eine MacAuth-Sicherung?")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Aus Datei importieren …") { Task { await ImportFlow.chooseFile(model: model) } }
                    .buttonStyle(.link)
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
        var parts = [String(localized: "\(session.rows.count) Konten gefunden. Es wird erst gespeichert, wenn du auf „Importieren“ klickst.")]
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
