import AuthCore
import SwiftUI

struct FirstRunView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                AppIconImage(size: 84)
                Text("Willkommen bei MacAuth").font(.system(size: 28, weight: .semibold))
                Text("Deine Codes bleiben auf diesem Mac.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                ChoiceCard(symbol: "qrcode.viewfinder", title: "Aus Google Authenticator importieren",
                           text: "Scanne den Export-QR-Code oder wähle einen Screenshot.") { model.sheet = .importer }
                ChoiceCard(symbol: "externaldrive.badge.checkmark", title: "Backup wiederherstellen",
                           text: "Öffne eine Backup-Datei und gib das Passwort ein.") { model.sheet = .restoreBackup }
                ChoiceCard(symbol: "square.and.pencil", title: "Manuell hinzufügen",
                           text: "Gib einen Setup-Schlüssel oder otpauth-Link ein.") { model.sheet = .add }
            }
            .frame(maxWidth: 760)
            Label("Erst wenn du etwas hinzufügst, legt MacAuth den geschützten Tresor an.", systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
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

    var body: some View {
        VStack(spacing: 18) {
            AppIconImage(size: 88)
            Text("MacAuth ist gesperrt").font(.system(size: 24, weight: .semibold))
            Button {
                Task { await model.unlock() }
            } label: {
                Label("Entsperren", systemImage: "touchid").font(.system(size: 14, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isUnlocking)
            notice
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if !model.suppressAutoPrompt, model.lockNotice == nil, NSApp.isActive { Task { await model.unlock() } }
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
            case .keyUnusable:
                Text("Der Schlüssel dieses Tresors ist auf diesem Mac nicht mehr nutzbar, zum Beispiel nach einer Neuinstallation oder einem anderen Mac. Deine Codes lassen sich nur noch aus einem Backup wiederherstellen.")
                    .foregroundStyle(.secondary)
                Button("Aus Backup wiederherstellen …") { model.sheet = .restoreBackup }
            case .corrupted:
                Text("Der Tresor ist beschädigt oder wurde verändert.").foregroundStyle(.secondary)
                if model.canRecoverPrevious {
                    Button("Vorherige Fassung wiederherstellen") { Task { await model.recoverPreviousGeneration() } }
                }
                Button("Aus Backup wiederherstellen …") { model.sheet = .restoreBackup }
            }
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
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
