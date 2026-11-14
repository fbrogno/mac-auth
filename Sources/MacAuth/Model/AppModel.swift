import AppKit
import AuthCore
import CryptoKit
import LocalAuthentication
import Observation

enum SidebarItem: Hashable {
    case all, favorites, group(UUID)
}

/// What a sheet over the main window shows. Cleared on lock.
enum ActiveSheet: Identifiable {
    case add
    case edit(UUID)
    case importer
    case review(ImportSession)
    case restoreBackup
    case exportBackup
    case transfer(Set<UUID>?)
    case newGroup
    case editGroup(UUID)
    case confirmDelete(UUID)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let id): "edit-\(id)"
        case .importer: "importer"
        case .review(let s): "review-\(s.id)"
        case .restoreBackup: "restore"
        case .exportBackup: "export"
        case .transfer: "transfer"
        case .newGroup: "newGroup"
        case .editGroup(let id): "editGroup-\(id)"
        case .confirmDelete(let id): "delete-\(id)"
        }
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Why the lock screen shows more than the unlock button.
enum LockNotice: Equatable {
    case cancelled
    case failed(String)
    case keyUnusable
    case corrupted
}

@MainActor @Observable
final class AppModel {
    enum Phase { case loading, firstRun, locked, unlocked }

    // MARK: State

    private(set) var phase: Phase = .loading
    private(set) var accounts: [Account] = []
    private(set) var groups: [AccountGroup] = []
    var sidebar: SidebarItem = .all
    var search = ""
    var selection: UUID?
    var sheet: ActiveSheet?
    var alert: AppAlert?
    private(set) var lockNotice: LockNotice?
    private(set) var isUnlocking = false
    private(set) var copiedID: UUID?
    private(set) var hasPreviousGeneration = false
    /// After a system lock (screen lock, sleep) the unlock prompt waits until the user is back.
    private(set) var suppressAutoPrompt = false
    /// Bumped to ask the search field for focus.
    private(set) var focusSearchTick = 0

    let settings: AppSettings
    let input = InputState()
    let importer = ImportCoordinator()
    let isDemo: Bool

    @ObservationIgnored private let store: VaultStore?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lockObserver: SystemLockObserver?
    @ObservationIgnored private var autoLockTimer: Timer?
    @ObservationIgnored private var copiedTask: Task<Void, Never>?

    init(settings: AppSettings? = nil) {
        self.settings = settings ?? AppSettings()
        self.isDemo = false
        self.store = VaultStore(url: Self.vaultURL)
    }

    /// Demo model for the documentation renderer: no vault, no files.
    init(demoPhase: Phase, accounts: [Account], groups: [AccountGroup], settings: AppSettings) {
        self.settings = settings
        self.isDemo = true
        self.store = nil
        self.phase = demoPhase
        self.accounts = accounts
        self.groups = groups
    }

    static var vaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacAuth", isDirectory: true).appendingPathComponent("vault.json")
    }

    // MARK: Start, unlock, lock

    func start() async {
        guard !started, let store else { return }
        started = true
        input.start()
        lockObserver = SystemLockObserver(onLock: { [weak self] in self?.lock(fromSystem: true) },
                                          onReturn: { [weak self] in self?.userReturned() })
        do {
            let state = try await store.load()
            hasPreviousGeneration = await store.hasPreviousGeneration
            switch state {
            case .empty, .unloaded:
                groups = AccountGroup.makeDefaults()
                phase = .firstRun
            case .locked, .unlocked:
                phase = .locked
                await unlock()
            }
        } catch {
            hasPreviousGeneration = await store.hasPreviousGeneration
            lockNotice = .corrupted
            phase = .locked
        }
    }

    func unlock() async {
        guard phase == .locked, !isUnlocking, let store else { return }
        isUnlocking = true
        lockNotice = nil
        defer { isUnlocking = false }
        do {
            let identifier = await store.protectorIdentifier
            let protector: any KeyProtector
            switch identifier {
            case "secure-enclave":
                protector = SecureEnclaveProtector(context: Self.makeContext())
            case "keychain":
                if settings.requireAuth, !(await authenticate(reason: String(localized: "MacAuth entsperren"))) {
                    lockNotice = .cancelled
                    return
                }
                protector = KeychainProtector()
            default:
                lockNotice = .corrupted
                return
            }
            let data = try await store.unlock(using: protector)
            show(data)
        } catch {
            lockNotice = Self.classify(error)
        }
    }

    private func show(_ data: VaultData) {
        accounts = data.accounts
        groups = data.groups
        phase = .unlocked
        search = ""
        selection = nil
        normalizeSelection()
        startAutoLock()
        focusSearch()
    }

    /// Drops everything decrypted. The clipboard timer keeps running on purpose.
    func lock(fromSystem: Bool = false) {
        guard phase == .unlocked else { return }
        suppressAutoPrompt = fromSystem
        autoLockTimer?.invalidate()
        autoLockTimer = nil
        sheet = nil
        alert = nil
        accounts = []
        groups = []
        search = ""
        selection = nil
        copiedID = nil
        phase = .locked
        lockNotice = nil
        let pending = saveTask
        Task { [store] in
            await pending?.value
            await store?.lock()
        }
    }

    /// Screen unlocked or app activated: offer the unlock prompt again.
    func userReturned() {
        suppressAutoPrompt = false
        guard phase == .locked, lockNotice == nil, NSApp.isActive else { return }
        Task { await unlock() }
    }

    private func startAutoLock() {
        autoLockTimer?.invalidate()
        input.lastActivity = Date()
        autoLockTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .unlocked, self.settings.autoLockMinutes > 0 else { return }
                if Date().timeIntervalSince(self.input.lastActivity) >= Double(self.settings.autoLockMinutes * 60) { self.lock() }
            }
        }
    }

    private static func makeContext() -> LAContext {
        let context = LAContext()
        context.localizedReason = String(localized: "MacAuth entsperren")
        return context
    }

    private static func classify(_ error: Error) -> LockNotice {
        switch error {
        case ProtectorError.userCancelled: .cancelled
        case ProtectorError.authenticationFailed: .failed(ErrorText.message(for: error))
        case ProtectorError.keyNotFound, ProtectorError.dataCorrupted, ProtectorError.secureEnclaveFailure,
             ProtectorError.secureEnclaveUnavailable: .keyUnusable
        case VaultError.corrupted, VaultError.unsupportedVersion: .corrupted
        default: .failed(ErrorText.message(for: error))
        }
    }

    /// Fresh Touch ID / password check for sensitive actions (export, QR codes).
    func authenticate(reason: String) async -> Bool {
        if isDemo { return true }
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError where error.code == .passcodeNotSet {
            return true
        } catch let error as LAError where [.userCancel, .systemCancel, .appCancel].contains(error.code) {
            return false
        } catch {
            alert = AppAlert(title: String(localized: "Authentifizierung nicht möglich"),
                             message: String(localized: "Die Abfrage mit Touch ID oder Passwort ist fehlgeschlagen."))
            return false
        }
    }

    /// Recovers the previous vault generation after the current file was damaged.
    func recoverPreviousGeneration() async {
        guard let store else { return }
        do {
            try await store.recoverPreviousGeneration()
            lockNotice = nil
            phase = .locked
            await unlock()
        } catch {
            alert = AppAlert(title: String(localized: "Wiederherstellen nicht möglich"), message: ErrorText.message(for: error))
        }
    }

    var canRecoverPrevious: Bool { hasPreviousGeneration }

    // MARK: Protector setting

    func setRequireAuth(_ on: Bool) async {
        guard let store, phase == .unlocked else { return }
        do {
            let protector: any KeyProtector = on && SecureEnclaveProtector.isAvailable
                ? SecureEnclaveProtector(context: Self.makeContext()) : KeychainProtector()
            try await store.changeProtector(to: protector)
            settings.requireAuth = on
        } catch {
            alert = AppAlert(title: String(localized: "Einstellung nicht geändert"), message: ErrorText.message(for: error))
        }
    }

    var secureEnclaveAvailable: Bool { SecureEnclaveProtector.isAvailable }

    // MARK: Persistence

    private var vaultData: VaultData { VaultData(accounts: accounts, groups: groups) }

    private func persist() {
        settings.lastAccountChange = Date().timeIntervalSince1970
        guard let store else { return }
        let data = vaultData
        let previous = saveTask
        saveTask = Task { [weak self] in
            await previous?.value
            do { try await store.save(data) } catch {
                self?.alert = AppAlert(title: String(localized: "Speichern fehlgeschlagen"), message: ErrorText.message(for: error))
            }
        }
    }

    /// Creates the vault (first start, or a replacement after a lost key) with the given content.
    private func createVault(_ data: VaultData, replacing: Bool) async -> Bool {
        guard let store else { return false }
        do {
            let protector: any KeyProtector = settings.requireAuth && SecureEnclaveProtector.isAvailable
                ? SecureEnclaveProtector(context: Self.makeContext()) : KeychainProtector()
            try await store.create(contents: data, protector: protector, replacingExisting: replacing)
            accounts = data.accounts
            groups = data.groups
            settings.lastAccountChange = Date().timeIntervalSince1970
            phase = .unlocked
            lockNotice = nil
            startAutoLock()
            normalizeSelection()
            focusSearch()
            return true
        } catch {
            alert = AppAlert(title: String(localized: "Tresor konnte nicht angelegt werden"), message: ErrorText.message(for: error))
            return false
        }
    }

    // MARK: Accounts

    func nextSortIndex() -> Int { (accounts.map(\.sortIndex).max() ?? -1) + 1 }

    /// Adds one account (manual form). On first start this creates the vault.
    func add(_ account: Account) async -> Bool {
        var account = account
        account.sortIndex = nextSortIndex()
        if phase == .firstRun {
            return await createVault(VaultData(accounts: [account], groups: groups), replacing: false)
        }
        accounts.append(account)
        persist()
        return true
    }

    func update(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        persist()
    }

    func delete(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        persist()
        normalizeSelection()
    }

    func togglePin(_ id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].pinned.toggle()
        persist()
    }

    func move(_ id: UUID, to groupID: UUID?) {
        guard let index = accounts.firstIndex(where: { $0.id == id }), accounts[index].groupID != groupID else { return }
        accounts[index].groupID = groupID
        persist()
    }

    /// Puts `id` in front of `target` in the custom order.
    func reorder(_ id: UUID, before target: UUID) {
        guard id != target else { return }
        var ordered = accounts.sorted { $0.sortIndex < $1.sortIndex }
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return }
        let moved = ordered.remove(at: from)
        guard let to = ordered.firstIndex(where: { $0.id == target }) else { return }
        ordered.insert(moved, at: to)
        for (position, account) in ordered.enumerated() {
            if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index].sortIndex = position }
        }
        persist()
    }

    func advanceHOTP(_ id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }), accounts[index].kind == .hotp else { return }
        accounts[index].advanceCounter()
        persist()
    }

    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }

    func group(_ id: UUID?) -> AccountGroup? { id.flatMap { id in groups.first { $0.id == id } } }

    // MARK: Groups

    func addGroup(_ group: AccountGroup) {
        groups.append(group)
        if phase == .unlocked { persist() }
    }

    func updateGroup(_ group: AccountGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index] = group
        persist()
    }

    func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        for index in accounts.indices where accounts[index].groupID == id { accounts[index].groupID = nil }
        if sidebar == .group(id) { sidebar = .all }
        persist()
    }

    func count(for item: SidebarItem) -> Int {
        switch item {
        case .all: accounts.count
        case .favorites: accounts.filter(\.pinned).count
        case .group(let id): accounts.filter { $0.groupID == id }.count
        }
    }

    // MARK: Listing

    /// The accounts of the current sidebar entry and search, in display order.
    var visibleAccounts: [Account] {
        let scoped: [Account]
        switch sidebar {
        case .all: scoped = accounts
        case .favorites: scoped = accounts.filter(\.pinned)
        case .group(let id): scoped = accounts.filter { $0.groupID == id }
        }
        let ordered = scoped.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.issuer.localizedCaseInsensitiveCompare($1.issuer) == .orderedAscending
        }
        return AccountSearch.filter(ordered, query: search, groupName: { self.group($0)?.name })
    }

    var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    func normalizeSelection() {
        let visible = visibleAccounts
        if let selection, visible.contains(where: { $0.id == selection }) { return }
        selection = visible.first?.id
    }

    enum Direction { case left, right, up, down }

    func moveSelection(_ direction: Direction, columns: Int) {
        let visible = visibleAccounts
        guard !visible.isEmpty else { return }
        guard let current = selection, let index = visible.firstIndex(where: { $0.id == current }) else {
            selection = visible.first?.id
            return
        }
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -max(columns, 1)
        case .down: step = max(columns, 1)
        }
        let target = index + step
        if (0..<visible.count).contains(target) { selection = visible[target].id }
        else if direction == .down, index < visible.count - 1, columns > 1 { selection = visible.last?.id }
    }

    func focusSearch() { focusSearchTick += 1 }

    // MARK: Copying

    func copy(_ id: UUID?, next: Bool = false) {
        guard let id, let account = account(id) else { return }
        let now = Date()
        guard let code = try? (next ? account.nextCode(at: now) : account.code(at: now)) else { return }
        ClipboardService.shared.copy(code, clearAfter: settings.clipboardClearSeconds)
        if next, account.kind == .hotp { advanceHOTP(id) }
        selection = id
        copiedID = id
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.copiedID = nil
        }
        if settings.hideAfterCopy { NSApp.hide(nil) }
    }

    func copyVisible(at position: Int) {
        let visible = visibleAccounts
        guard visible.indices.contains(position) else { return }
        copy(visible[position].id)
    }

    // MARK: Import

    func makeSession(source: ImportSession.Source, accounts found: [Account], skipped: [String] = [],
                     backup: VaultData? = nil) -> ImportSession {
        let defaultGroup = UUID(uuidString: settings.defaultGroupID).flatMap { id in groups.contains { $0.id == id } ? id : nil }
        let session = ImportSession(source: source, accounts: found, skipped: skipped, existing: accounts,
                                    existingGroups: groups, backupGroups: backup?.groups ?? [], defaultGroupID: defaultGroup)
        session.replacesVault = phase == .locked
        return session
    }

    /// Stores the confirmed rows. First start (or a replaced vault) creates the vault.
    func commit(_ session: ImportSession) async -> Bool {
        let chosen = session.rows.filter(\.include)
        guard !chosen.isEmpty else { return false }
        let used = Set(chosen.compactMap(\.groupID))
        var newGroups = groups
        for group in session.availableGroups where used.contains(group.id) && !newGroups.contains(where: { $0.id == group.id }) {
            newGroups.append(group)
        }
        var index = nextSortIndex()
        let added = chosen.map { row -> Account in
            var account = row.account
            account.groupID = row.groupID
            account.sortIndex = index
            index += 1
            return account
        }
        let fromBackup = session.source == .backup
        switch phase {
        case .firstRun, .locked:
            let replacing = phase == .locked
            let ok = await createVault(VaultData(accounts: added, groups: replacing ? session.availableGroups : newGroups),
                                       replacing: replacing)
            if ok, fromBackup { settings.lastBackupExport = Date().timeIntervalSince1970 + 1 }
            return ok
        case .unlocked:
            groups = newGroups
            accounts.append(contentsOf: added)
            persist()
            if fromBackup { settings.lastBackupExport = Date().timeIntervalSince1970 + 1 }
            return true
        case .loading:
            return false
        }
    }
}
