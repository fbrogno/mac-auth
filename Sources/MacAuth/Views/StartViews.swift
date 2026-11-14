import AuthCore
import SwiftUI

struct FirstRunView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                IconGlow(size: 84)
                Text("Willkommen bei MacAuth").font(.system(size: 28, weight: .semibold))
                Text("Deine Codes bleiben auf diesem Mac.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                ChoiceCard(symbol: "qrcode.viewfinder", title: "Aus Google Authenticator importieren",
                           text: "Scanne den Export-QR-Code oder wähle einen Screenshot.") { model.sheet = .importer }
                ChoiceCard(symbol: "externaldrive.badge.checkmark", title: "Backup wiederherstellen",
                           text: "Öffne eine Backup-Datei und gib das Passwort ein.") { model.sheet = .restoreBackup(preset: nil, replace: false) }
                ChoiceCard(symbol: "square.and.pencil", title: "Manuell hinzufügen",
                           text: "Gib einen Setup-Schlüssel oder otpauth-Link ein.") { model.sheet = .add }
            }
            .frame(maxWidth: 760)
            FileImportRow { Task { await ImportFlow.chooseFile(model: model) } }
                .frame(maxWidth: 760)
            Label("Erst wenn du etwas hinzufügst, legt MacAuth den geschützten Tresor an.", systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The fourth, smaller way in: an export file of another authenticator app.
private struct FileImportRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.arrow.up").font(.system(size: 17)).foregroundStyle(Color.accentColor).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Aus Datei importieren …").font(.system(size: 13.5, weight: .semibold))
                    Text("Exportdatei aus Aegis, 2FAS oder Ente Auth, oder eine MacAuth-Sicherung. Du kannst die Datei auch auf das Fenster ziehen.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovering ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.1), lineWidth: hovering ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
    }
}

private struct ChoiceCard: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 196, maxHeight: 196, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(hovering ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.1), lineWidth: hovering ? 1.5 : 1))
            .shadow(color: .black.opacity(hovering ? 0.14 : 0.05), radius: hovering ? 10 : 3, y: hovering ? 4 : 1)
            .offset(y: hovering && !reduceMotion ? -2 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: hovering)
        .pointerStyle(.link)
    }
}

struct LockedView: View {
    @Bindable var model: AppModel
    @State private var showMore: Bool

    init(model: AppModel, showMore: Bool = false) {
        self.model = model
        _showMore = State(initialValue: showMore)
    }

    private var recoveryButtons: some View {
        HStack(spacing: 10) {
            // Both ask for Touch ID / password first: a restored vault must never open the lock screen without it.
            Button("Aus Backup wiederherstellen …") { Task { await model.beginRecovery(.restoreBackup(preset: nil, replace: true)) } }
            Button("Frühere Fassung wiederherstellen …") { Task { await model.beginRecovery(.rescue) } }
        }
        .padding(.top, 4)
    }

    private var needsRetry: Bool {
        switch model.lockNotice {
        case .retryLater, .cannotOpen: true
        default: false
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            IconGlow(size: 88)
            Text(model.lockNotice == .cannotOpen ? "Tresor lässt sich nicht öffnen" : "MacAuth ist gesperrt")
                .font(.system(size: 24, weight: .semibold))
            Button {
                Task { await model.unlock() }
            } label: {
                Label(needsRetry ? "Erneut versuchen" : "Entsperren", systemImage: needsRetry ? "arrow.clockwise" : "touchid")
                    .font(.system(size: 14, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 3)
            }
            .primaryButtonStyle().controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isUnlocking)
            notice
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No prompt here on purpose: the model asks at app start, when the app comes back to the front, or on the button.
    }

    /// For temporary or unclear failures the recovery paths stay out of the way until asked for.
    @ViewBuilder
    private var moreOptions: some View {
        if showMore {
            recoveryButtons
        } else {
            Button("Weitere Möglichkeiten …") { showMore = true }.buttonStyle(.link)
        }
    }

    @ViewBuilder
    private var notice: some View {
        VStack(spacing: 10) {
            switch model.lockNotice {
            case .none:
                EmptyView()
            case .cancelled:
                Text("Entsperren abgebrochen. Tippe auf „Entsperren“, wenn du bereit bist.")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                moreOptions
            case .retryLater:
                Text("Der Schlüssel ließ sich gerade nicht lesen. Das ist meist vorübergehend, zum Beispiel bei gesperrtem Bildschirm. Versuche es gleich noch einmal. Deine Daten sind nicht verloren.")
                    .foregroundStyle(.secondary)
                moreOptions
            case .cannotOpen:
                Text("Wurde dieser Tresor auf einem anderen Mac oder vor dem Zurücksetzen angelegt? Er liegt noch auf diesem Mac, es wurde nichts gelöscht. Versuche es zuerst erneut, zum Beispiel nach einem Neustart. Hilft das nicht, kannst du dein Backup einspielen oder eine frühere Fassung zurückholen.")
                    .foregroundStyle(.secondary)
                recoveryButtons
            }
            if let warning = model.lockWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(.top, 6)
            }
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct AppIconImage: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
