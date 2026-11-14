import AuthCore
import SwiftUI

struct MainView: View {
    @Bindable var model: AppModel
    enum Focus { case search, content }
    @FocusState var focus: Focus?
    @State private var columns = 2
    @Environment(\.fixedNow) private var fixedNow

    private var listMode: Bool { model.settings.listMode }

    var body: some View {
        if fixedNow != nil {
            documentationBody   // NavigationSplitView cannot be captured off screen; see Render/MainRender.swift
        } else {
            liveBody
        }
    }

    private var liveBody: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
        } detail: {
            content
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                SearchField(text: $model.search, focus: $focus, onKey: { handle($0, inSearch: true) }, onSubmit: { model.copy(model.selection) })
                    .frame(minWidth: 200, idealWidth: 320, maxWidth: 380)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Darstellung", selection: Binding(get: { model.settings.listMode }, set: { model.settings.listMode = $0 })) {
                    Label("Raster", systemImage: "square.grid.2x2").tag(false)
                    Label("Liste", systemImage: "list.bullet").tag(true)
                }
                .pickerStyle(.segmented)
                .help(Text("Darstellung wechseln"))
                Menu {
                    Button("Neues Konto …") { model.sheet = .add }
                    Divider()
                    Button("Aus Google Authenticator importieren …") { model.sheet = .importer }
                    Button("Backup wiederherstellen …") { model.sheet = .restoreBackup }
                } label: {
                    Label("Hinzufügen", systemImage: "plus")
                } primaryAction: {
                    model.sheet = .add
                }
                .help(Text("Konto hinzufügen (⌘N)"))
            }
        }
        .onChange(of: model.focusSearchTick) { focus = .search }
        .onChange(of: model.sheet == nil) { _, closed in if closed { focus = .search } }
        .onAppear { DispatchQueue.main.async { focus = .search } }
        .onChange(of: model.search) {
            let text = model.search
            if OTPAuthURI.isOTPAuthURI(text) || MigrationCodec.isMigrationURI(text) {
                model.search = ""
                ImportFlow.handle(text: text, model: model)
            } else {
                model.selection = model.visibleAccounts.first?.id
            }
        }
        .onChange(of: model.sidebar) { model.normalizeSelection() }
        .onChange(of: model.accounts.count) { model.normalizeSelection() }
        .background(shortcutButtons)
    }

    var title: String {
        switch model.sidebar {
        case .all: String(localized: "Alle")
        case .favorites: String(localized: "Favoriten")
        case .group(let id): model.group(id)?.name ?? "MacAuth"
        }
    }

    var subtitle: String {
        let n = model.visibleAccounts.count
        return String(localized: "\(n) Konten")
    }

    // MARK: Content

    @ViewBuilder
    var content: some View {
        let visible = model.visibleAccounts
        Group {
            if visible.isEmpty {
                emptyState
            } else {
                Ticker { now in
                    ScrollViewReader { proxy in
                        ScrollView {
                            if listMode { list(visible, now: now) } else { grid(visible, now: now) }
                        }
                        .scrollContentBackground(.hidden)
                        .onChange(of: model.selection) { _, id in
                            if let id { withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(id) } }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focused($focus, equals: .content)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { handle($0, inSearch: false) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            columns = listMode ? 1 : max(1, Int((width - 40 + 12) / (260 + 12)))
        }
        .onChange(of: listMode) { columns = listMode ? 1 : max(1, columns) }
    }

    private func grid(_ visible: [Account], now: Date) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: max(columns, 1)), spacing: 12) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, account in
                AccountCard(display: display(account, now), groupColor: groupColor(account), badge: badge(index),
                            isSelected: model.selection == account.id, isCopied: model.copiedID == account.id,
                            revealCode: !model.settings.hideCodes,
                            onCopy: { model.copy(account.id) }, onNextHOTP: { model.advanceHOTP(account.id) })
                    .id(account.id)
                    .modifier(AccountInteractions(model: model, account: account))
            }
        }
        .padding(20)
    }

    private func list(_ visible: [Account], now: Date) -> some View {
        LazyVStack(spacing: 2) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, account in
                AccountRow(display: display(account, now), groupColor: groupColor(account), badge: badge(index),
                           isSelected: model.selection == account.id, isCopied: model.copiedID == account.id,
                           revealCode: !model.settings.hideCodes,
                           onCopy: { model.copy(account.id) }, onNextHOTP: { model.advanceHOTP(account.id) })
                    .id(account.id)
                    .modifier(AccountInteractions(model: model, account: account))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private func display(_ account: Account, _ now: Date) -> AccountDisplay {
        AccountDisplay(account: account, now: now, groupName: model.group(account.groupID)?.name)
    }

    private func groupColor(_ account: Account) -> Color? {
        model.group(account.groupID).map { Color(hex: $0.colour) }
    }

    private func badge(_ index: Int) -> Int? {
        model.input.commandHeld && index < 9 ? index + 1 : nil
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isSearching {
            ContentUnavailableView {
                Label("Keine Treffer", systemImage: "magnifyingglass")
            } description: {
                Text("Zu „\(model.search)“ gibt es kein Konto. Du kannst es neu anlegen.")
            } actions: {
                Button("Suche löschen") { model.search = "" }
                Button("Neues Konto …") { model.sheet = .add }
            }
        } else if case .favorites = model.sidebar {
            ContentUnavailableView {
                Label("Noch keine Favoriten", systemImage: "star")
            } description: {
                Text("Markiere ein Konto per Rechtsklick als Favorit, dann steht es hier und immer ganz oben.")
            }
        } else if case .group = model.sidebar {
            ContentUnavailableView {
                Label("Diese Gruppe ist leer", systemImage: "tray")
            } description: {
                Text("Ziehe Konten auf die Gruppe in der Seitenleiste oder lege ein neues an.")
            } actions: {
                Button("Neues Konto …") { model.sheet = .add }
            }
        } else {
            ContentUnavailableView {
                Label("Noch keine Konten", systemImage: "key.horizontal")
            } description: {
                Text("Importiere deine Codes aus Google Authenticator oder lege ein Konto von Hand an.")
            } actions: {
                Button("Importieren …") { model.sheet = .importer }
                Button("Neues Konto …") { model.sheet = .add }
            }
        }
    }

    // MARK: Keys

    private func handle(_ press: KeyPress, inSearch: Bool) -> KeyPress.Result {
        switch press.key {
        case .upArrow: model.moveSelection(.up, columns: columns); return .handled
        case .downArrow: model.moveSelection(.down, columns: columns); return .handled
        case .leftArrow:
            if inSearch, !model.search.isEmpty { return .ignored }
            model.moveSelection(.left, columns: columns); return .handled
        case .rightArrow:
            if inSearch, !model.search.isEmpty { return .ignored }
            model.moveSelection(.right, columns: columns); return .handled
        case .return:
            if inSearch { return .ignored }   // the field's onSubmit copies
            model.copy(model.selection); return .handled
        case .escape:
            if !model.search.isEmpty { model.search = ""; return .handled }
            if inSearch { focus = .content; return .handled }
            return .ignored
        case .delete:
            if !inSearch, !model.search.isEmpty { model.search.removeLast(); return .handled }
            return .ignored
        default: break
        }
        guard !inSearch, press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        let text = press.characters
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }) else { return .ignored }
        model.search += text
        return .handled
    }

    private var shortcutButtons: some View {
        ZStack {
            ForEach(0..<9, id: \.self) { index in
                Button { model.copyVisible(at: index) } label: { EmptyView() }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Drag, drop-to-reorder and context menu shared by cards and rows.
struct AccountInteractions: ViewModifier {
    let model: AppModel
    let account: Account

    func body(content: Content) -> some View {
        content
            .draggable(account.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                guard !model.isSearching, let id = items.compactMap({ UUID(uuidString: $0) }).first else { return false }
                model.reorder(id, before: account.id)
                return true
            }
            .contextMenu { AccountMenu(model: model, account: account) }
    }
}

struct AccountMenu: View {
    let model: AppModel
    let account: Account

    var body: some View {
        Button("Code kopieren") { model.copy(account.id) }
        if account.kind == .hotp {
            Button("Nächsten Code kopieren und weiterzählen") { model.copy(account.id, next: true) }
        } else {
            Button("Nächsten Code kopieren") { model.copy(account.id, next: true) }
        }
        Divider()
        Button("Bearbeiten …") { model.sheet = .edit(account.id) }
        if account.pinned {
            Button("Aus Favoriten entfernen") { model.togglePin(account.id) }
        } else {
            Button("Zu Favoriten hinzufügen") { model.togglePin(account.id) }
        }
        Menu("In Gruppe verschieben") {
            Button("Keine Gruppe") { model.move(account.id, to: nil) }.disabled(account.groupID == nil)
            Divider()
            ForEach(model.groups) { group in
                Button(group.name) { model.move(account.id, to: group.id) }.disabled(account.groupID == group.id)
            }
        }
        Button("QR-Code anzeigen …") {
            Task {
                if await model.authenticate(reason: String(localized: "QR-Code des Kontos anzeigen")) { model.sheet = .transfer([account.id]) }
            }
        }
        Divider()
        Button("Löschen …", role: .destructive) { model.sheet = .confirmDelete(account.id) }
    }
}

struct SearchField: View {
    @Binding var text: String
    var focus: FocusState<MainView.Focus?>.Binding
    let onKey: (KeyPress) -> KeyPress.Result
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Suchen", text: $text)
                .textFieldStyle(.plain)
                .focused(focus, equals: .search)
                .onSubmit(onSubmit)
                .onKeyPress(phases: [.down, .repeat]) { onKey($0) }
                .accessibilityLabel(Text("Konten durchsuchen"))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel(Text("Suche löschen"))
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
