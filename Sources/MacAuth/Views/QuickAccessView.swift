import AppKit
import AuthCore
import SwiftUI

/// Content of the quick access panel. Thin: what is listed and what a key does is decided in `AuthCore.QuickAccess`,
/// the window and the keys live in `QuickAccessController`. Without a vault unlocked there is no account data here.
struct QuickAccessView: View {
    @Bindable var model: AppModel
    @Bindable var state: QuickPanelState
    /// nil in the documentation renderer.
    var controller: QuickAccessController?

    @FocusState private var searchFocused: Bool
    @Environment(\.fixedNow) private var fixedNow

    var body: some View {
        VStack(spacing: 0) {
            switch QuickAccess.content(for: model.phase) {
            case .list: ListContent(model: model, state: state, controller: controller, searchFocused: $searchFocused)
            case .locked: LockedContent(model: model, controller: controller)
            case .unavailable: UnavailableContent(controller: controller)
            }
        }
        .frame(width: QuickAccess.panelWidth)
        .modifier(QuickPanelBackground())
        .environment(\.protectScreen, model.settings.protectScreen)
        .background(WindowConfigurator(isMainWindow: false))   // sharingType follows the security setting, live
        .onGeometryChange(for: CGSize.self) { $0.size } action: { controller?.contentSizeChanged($0) }
        .onAppear { if fixedNow == nil { DispatchQueue.main.async { searchFocused = true } } }
    }
}

// MARK: - List

private struct ListContent: View {
    @Bindable var model: AppModel
    @Bindable var state: QuickPanelState
    var controller: QuickAccessController?
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        let rows = QuickAccess.rows(from: model.accounts, query: state.query, groupName: { model.group($0)?.name })
        VStack(spacing: 0) {
            searchField
            Divider()
            if rows.isEmpty {
                Text(model.accounts.isEmpty ? "Noch keine Konten" : "Keine Treffer")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 26)
                Divider()
                footer(rows, now: Date())
            } else {
                Ticker { now in
                    VStack(spacing: 0) {
                        VStack(spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, account in
                                QuickRow(display: AccountDisplay(account: account, now: now, groupName: nil), number: index + 1,
                                         isSelected: state.selectedIndex == index, isCopied: state.copiedID == account.id,
                                         revealCode: !model.settings.hideCodes, selectionReveals: state.selectionExplicit,
                                         onCopy: { state.selectedIndex = index; controller?.copy(.command(index + 1)) })
                            }
                        }
                        .padding(8)
                        Divider()
                        footer(rows, now: now)
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(.secondary)
            TextField("Suchen", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .light))
                .focused(searchFocused)
                .accessibilityLabel(Text("Konten durchsuchen"))
            if !state.query.isEmpty {
                Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel(Text("Suche löschen"))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 15)
    }

    private func footer(_ rows: [Account], now: Date) -> some View {
        let selected = state.selectedIndex.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
        return HStack(spacing: 12) {
            Group {
                if let selected, selected.kind == .hotp {
                    Text("↵ kopiert den nächsten Code und zählt weiter").foregroundStyle(.secondary)
                } else if let selected, QuickAccess.isExpiring(kind: selected.kind, remaining: selected.remainingSeconds(at: now)) {
                    Text("↵ kopiert den aktuellen Code, ⌥↵ den nächsten").foregroundStyle(Color.red)
                } else {
                    Text("↵ kopieren · ⌘1–⌘9 direkt").foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Text("esc schließen").foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 20).padding(.vertical, 9)
    }
}

/// One account row, in the visual language of `AccountRow`: monogram tile, issuer and name, code in monospaced
/// grouped digits (red when it is about to expire, with the next code small), countdown ring.
private struct QuickRow: View {
    let display: AccountDisplay
    let number: Int
    let isSelected: Bool
    let isCopied: Bool
    let revealCode: Bool
    /// False while the first row is only preselected automatically (hidden-codes mode must not reveal it).
    let selectionReveals: Bool
    let onCopy: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var account: Account { display.account }
    private var codeVisible: Bool { revealCode || hovering || (isSelected && selectionReveals) }
    private var expiring: Bool { QuickAccess.isExpiring(kind: account.kind, remaining: display.remaining) }

    var body: some View {
        HStack(spacing: 12) {
            MonogramTile(account: account, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(account.issuer.isEmpty ? account.name : account.issuer).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if account.pinned { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                }
                if !account.issuer.isEmpty {
                    Text(account.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isCopied {
                Label("Kopiert", systemImage: "checkmark.circle.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.green)
            } else {
                if let next = display.nextCode, codeVisible {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("Danach").font(.system(size: 9)).foregroundStyle(.tertiary)
                        Text(next).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Text(codeVisible ? display.groupedCode : "••• •••")
                    .font(.system(size: 21, weight: .medium).monospacedDigit())
                    .foregroundStyle(expiring ? Color.red : Color.primary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: display.code)
            }
            if account.kind == .totp {
                CountdownRing(remaining: display.remaining, period: account.period, size: 24, showsNumber: false)
            } else {
                Image(systemName: "arrow.clockwise").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 24, height: 24)
            }
            Text("⌘\(number)").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.tertiary).frame(width: 26, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(
            isCopied ? Color.green.opacity(0.14) : isSelected ? Color.accentColor.opacity(0.14) : hovering ? Color.primary.opacity(0.05) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(isSelected ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onCopy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.accessibilitySummary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Kopieren"), onCopy)
    }
}

// MARK: - Locked, unavailable

/// No account data at all: a lock symbol and the unlock button (the main window's unlock, nothing else).
private struct LockedContent: View {
    @Bindable var model: AppModel
    var controller: QuickAccessController?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 30)).foregroundStyle(.secondary).padding(.top, 6)
            Text("MacAuth ist gesperrt").font(.system(size: 17, weight: .semibold))
            if model.lockNotice == .cannotOpen {
                Text("Der Tresor lässt sich nicht öffnen. Öffne MacAuth, dort stehen die weiteren Möglichkeiten.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button("MacAuth öffnen") { controller?.openMainWindow() }.primaryButtonStyle().controlSize(.large)
            } else {
                Button { controller?.unlock() } label: {
                    Label(model.isUnlocking ? "Warte auf Touch ID …" : "Mit Touch ID entsperren", systemImage: "touchid")
                        .font(.system(size: 14, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 2)
                }
                .primaryButtonStyle().controlSize(.large)
                .disabled(model.isUnlocking)
                if let note = notice {
                    Text(note).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            Text("esc schließen").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
        }
        .padding(.horizontal, 28).padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    private var notice: String? {
        switch model.lockNotice {
        case .cancelled: String(localized: "Entsperren abgebrochen.")
        case .failed, .retryLater: String(localized: "Entsperren nicht möglich. Versuche es noch einmal.")
        case .cannotOpen, .none: nil
        }
    }
}

/// Starting up or no vault yet: nothing to list, the main window is the place.
private struct UnavailableContent: View {
    var controller: QuickAccessController?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.horizontal").font(.system(size: 28)).foregroundStyle(.secondary).padding(.top, 6)
            Text("Hier ist noch nichts zu kopieren. Öffne MacAuth, um loszulegen.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("MacAuth öffnen") { controller?.openMainWindow() }.primaryButtonStyle().controlSize(.large)
        }
        .padding(.horizontal, 28).padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Background

/// Liquid Glass on macOS 26, a blurred material before; solid with "Reduce transparency" (and in documentation images,
/// which are captured off screen where glass and behind-window blur are not drawn).
private struct QuickPanelBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.fixedNow) private var fixedNow

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        if reduceTransparency || fixedNow != nil {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.14)))
                .clipShape(shape)
        } else if #available(macOS 26, *) {
            content.floatingGlass(shape).clipShape(shape)
        } else {
            content
                .background { BehindWindowBlur().clipShape(shape) }
                .overlay(shape.strokeBorder(Color.primary.opacity(0.14)))
                .clipShape(shape)
        }
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
