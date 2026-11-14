import AppKit
import AuthCore
import CryptoKit
import LocalAuthentication
import Carbon.HIToolbox
import Observation

enum SidebarItem: Hashable {
    case all, favorites, group(UUID)
}

/// What a sheet over the main window shows. Cleared on lock; `isAllowed(in:)` keeps locked and first-start
/// states from showing sheets that touch the vault.
enum ActiveSheet: Identifiable {
    case add
    case edit(UUID)
    case importer
    case review(ImportSession)
    case restoreBackup(preset: BackupPreset?, replace: Bool)
    case exportBackup
    case exportPlain
    case transfer(Set<UUID>?)
    case newGroup
    case editGroup(UUID)
    case confirmDelete(UUID)
    case rescue

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let id): "edit-\(id)"
        case .importer: "importer"
        case .review(let s): "review-\(s.id)"
        case .restoreBackup(let p, let replace): "restore-\(p?.id.uuidString ?? "none")-\(replace)"
        case .exportBackup: "export"
        case .exportPlain: "exportPlain"
        case .transfer: "transfer"
        case .newGroup: "newGroup"
        case .editGroup(let id): "editGroup-\(id)"
        case .confirmDelete(let id): "delete-\(id)"
        case .rescue: "rescue"
        }
    }

    func isAllowed(in phase: AppPhase) -> Bool {
        switch self {
        case .rescue: return phase == .locked
        case .restoreBackup(_, let replace): return replace ? phase == .locked : (phase == .firstRun || phase == .unlocked)
        case .review(let session):
            return session.intent == .replaceVault ? phase == .locked : (phase == .firstRun || phase == .unlocked)
        case .add, .importer: return phase == .firstRun || phase == .unlocked
        case .exportBackup, .exportPlain, .transfer, .edit, .newGroup, .editGroup, .confirmDelete: return phase == .unlocked
        }
    }
}

/// A backup file already read (dropped or chosen), waiting for its password.
struct BackupPreset: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
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
    /// Temporary: Mac locked, no prompt possible, unknown Secure Enclave state. Try again later.
    case retryLater
    /// The vault could not be opened (key not found, file damaged). Nothing is deleted.
    case cannotOpen
}

enum Protection: Equatable {
    case unknown, secureEnclave, keychain
}

/// A vault file the user can bring back.
struct RescueEntry: Identifiable {
    enum Kind { case previous, replaced(ReplacedVaultFile), demo }
    let id: String
    let kind: Kind
    let date: Date
    let protector: String?
    var isPrevious: Bool { if case .replaced = kind { false } else { id == "previous" } }
}

/// Phase and lock generation at the moment something started; later steps check it still holds.
struct Ticket {
    let phase: AppPhase
    let generation: Int
}

@MainActor @Observable
final class AppModel {
    typealias Phase = AppPhase

    // MARK: State

    private(set) var phase: Phase = .loading
    private(set) var accounts: [Account] = []
    private(set) var groups: [AccountGroup] = []
    var sidebar: SidebarItem = .all
    var search = ""
    var selection: UUID? {
        didSet { if selection != oldValue, !settingSelectionAutomatically { selectionExplicit = true } }
    }
    /// True once the user moved or clicked the selection; the automatic first-card selection does not reveal hidden codes.
    private(set) var selectionExplicit = false
    var sheet: ActiveSheet? {
        didSet { if let sheet, !sheet.isAllowed(in: phase) { self.sheet = nil } }
    }
    var alert: AppAlert?
    private(set) var lockNotice: LockNotice?
    private(set) var isUnlocking = false
    private(set) var copiedID: UUID?
    private(set) var hasPreviousGeneration = false
    private(set) var protection: Protection = .unknown
    /// Bumped to ask the search field for focus.
    private(set) var focusSearchTick = 0
    var hotKeyError: String?
    /// Set when the last change could not be saved while locking; stays on the lock screen until the next unlock.
    private(set) var lockWarning: String?
    /// After restoring a version with weaker protection than this Mac can do: offer the Secure Enclave, never switch silently.
    private(set) var offerEnclaveUpgrade = false
    /// Whether the vault asks for Touch ID / password in the app (header of the vault file, not a preference).
    private(set) var appLockRequired = true
    /// A camera scan is running (counts as activity for up to 15 minutes).
    var cameraScanning = false
    /// Shown as a progress overlay while a file is read and recognised.
    private(set) var busyText: String?

    func setBusy(_ text: String?) { busyText = text }

    let settings: AppSettings
    let input = InputState()
    let importer = ImportCoordinator()
    let isDemo: Bool

    @ObservationIgnored private(set) var epoch = LockEpoch()
    @ObservationIgnored private var prompt = UnlockPromptPolicy()
    @ObservationIgnored private let store: VaultStore?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var saveSeq = 0
    @ObservationIgnored private var savedSeq = 0
    @ObservationIgnored private var settingSelectionAutomatically = false
    @ObservationIgnored private var lockObserver: SystemLockObserver?
    @ObservationIgnored private var autoLockTimer: Timer?
    @ObservationIgnored private var copiedTask: Task<Void, Never>?
    @ObservationIgnored private var keepAliveSince: Date?
    @ObservationIgnored private let demoRescue: [RescueEntry]

    init(settings: AppSettings? = nil) {
        self.settings = settings ?? AppSettings()
        self.isDemo = false
        self.store = VaultStore(url: Self.vaultURL)
        self.demoRescue = []
    }

    /// Demo model for the documentation renderer and `--demo`: no vault, no files.
    init(demoPhase: Phase, accounts: [Account], groups: [AccountGroup], settings: AppSettings,
         lockNotice: LockNotice? = nil, rescue: [RescueEntry] = [], protection: Protection = .secureEnclave) {
        self.settings = settings
        self.isDemo = true
        self.store = nil
        self.phase = demoPhase
        self.accounts = accounts
        self.groups = groups
        self.lockNotice = lockNotice
        self.demoRescue = rescue
        self.protection = protection
        self.hasPreviousGeneration = !rescue.isEmpty
    }

    static var vaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacAuth", isDirectory: true).appendingPathComponent("vault.json")
    }

    // MARK: Tickets (late results must not act on a different state)

    var ticket: Ticket { Ticket(phase: phase, generation: epoch.generation) }

    func isCurrent(_ ticket: Ticket) -> Bool {
        ticket.phase == phase && epoch.isCurrent(ticket.generation)
    }

    // MARK: Start, unlock, lock

    func start() async {
        guard !started, let store else { return }
        started = true
        input.start()
        applyHotKey()
        lockObserver = SystemLockObserver(onLock: { [weak self] in self?.lock(fromSystem: true) },
                                          onReturn: { [weak self] in self?.userReturned() },
                                          onResign: { [weak self] in self?.appResigned() })
        do {
            let state = try await store.load()
            hasPreviousGeneration = await store.hasPreviousGeneration
            await refreshProtection()
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
            lockNotice = .cannotOpen
            phase = .locked
        }
    }

    /// `explicit`: the user pressed "Unlock" (a prompt at app start also counts).
    func unlock() async {
        guard phase == .locked, !isUnlocking, let store else { return }
        prompt.didPrompt()
        let generation = epoch.generation
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
                if await store.requiresAppAuthentication, !(await authenticate(reason: String(localized: "MacAuth entsperren"))) {
                    if epoch.isCurrent(generation) { lockNotice = .cancelled }
                    return
                }
                protector = KeychainProtector()
            default:
                lockNotice = .cannotOpen
                return
            }
            let data = try await store.unlock(using: protector)
            guard epoch.isCurrent(generation), phase == .locked else {
                await store.lock()   // locked while the prompt was open: drop the result
                return
            }
            show(data)
            lockWarning = nil
            await refreshProtection()
            startOrphanCleanup(generation: generation)
        } catch {
            guard epoch.isCurrent(generation) else { return }
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

    /// Locks at once: the generation changes (results of running tasks are dropped), the UI state is cleared,
    /// and the store is locked after writing anything not yet saved. The clipboard timer keeps running.
    func lock(fromSystem: Bool = false) {
        epoch.bump()
        prompt.didLock()
        let wasUnlocked = phase == .unlocked
        let unsaved: VaultData? = wasUnlocked && savedSeq != saveSeq ? VaultData(accounts: accounts, groups: groups) : nil
        autoLockTimer?.invalidate()
        autoLockTimer = nil
        keepAliveSince = nil
        sheet = nil
        alert = nil
        importer.reset()
        copiedTask?.cancel()
        copiedID = nil
        if wasUnlocked {
            accounts = []
            groups = []
            search = ""
            settingSelectionAutomatically = true
            selection = nil
            settingSelectionAutomatically = false
            phase = .locked
            lockNotice = nil
        }
        savedSeq = saveSeq
        Task { [weak self, store] in
            if let unsaved {
                do { try await store?.save(unsaved) } catch {
                    // Locking still happens; the lock screen says plainly that the last change was not written.
                    self?.lockWarning = String(localized: "Die letzte Änderung konnte nicht gespeichert werden: \(ErrorText.message(for: error))")
                }
            }
            await store?.lock()
        }
    }

    /// Screen unlocked or app activated: offer the unlock prompt only if the app was in the background while locked.
    func userReturned() {
        guard phase == .locked, lockNotice == nil, NSApp.isActive, prompt.autoAllowed else { return }
        Task { await unlock() }
    }

    private func appResigned() {
        if phase == .locked { prompt.appResignedWhileLocked() }
    }

    /// The user brought the window forward on purpose (global shortcut): unlock prompt allowed.
    func userRequestedShow() {
        focusSearch()
        if phase == .locked, lockNotice == nil || lockNotice == .cancelled { Task { await unlock() } }
    }

    var autoPromptAllowed: Bool { prompt.autoAllowed }

    /// After any failed unlock except the user's own cancel the vault can be replaced from a backup (the old file is kept).
    var canReplaceVault: Bool {
        guard phase == .locked else { return false }
        switch lockNotice {
        case .failed, .retryLater, .cannotOpen: return true
        case .cancelled, .none: return false
        }
    }

    private func startAutoLock() {
        autoLockTimer?.invalidate()
        input.lastActivity = Date()
        autoLockTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .unlocked, self.settings.autoLockMinutes > 0 else { return }
                if self.importInProgress { self.input.lastActivity = Date() }
                if Date().timeIntervalSince(self.input.lastActivity) >= Double(self.settings.autoLockMinutes * 60) { self.lock() }
            }
        }
    }

    /// A running camera scan counts as activity for up to 15 minutes. An open import or review sheet extends the
    /// auto-lock by at most one more interval, never more.
    private var importInProgress: Bool {
        var sheetOpen = importer.progress != nil
        switch sheet {
        case .importer, .review: sheetOpen = true
        default: break
        }
        guard sheetOpen || cameraScanning else { keepAliveSince = nil; return false }
        let since = keepAliveSince ?? Date()
        keepAliveSince = since
        let elapsed = Date().timeIntervalSince(since)
        if cameraScanning, elapsed < 15 * 60 { return true }
        return sheetOpen && elapsed < Double(settings.autoLockMinutes * 60)
    }

    private static func makeContext() -> LAContext {
        let context = LAContext()
        context.localizedReason = String(localized: "MacAuth entsperren")
        return context
    }

    /// Maps a failed unlock to what the lock screen shows. Only the user's own cancel offers nothing more; every
    /// other failure leaves the recovery paths available (hidden behind "Weitere Möglichkeiten" for temporary ones).
    static func classify(_ error: Error) -> LockNotice {
        switch error {
        case ProtectorError.userCancelled: .cancelled
        case VaultError.locked: .cancelled
        case ProtectorError.authenticationFailed: .failed(ErrorText.message(for: error))
        case ProtectorError.interactionNotAllowed, ProtectorError.secureEnclaveFailure, ProtectorError.keychainFailure: .retryLater
        case ProtectorError.keyNotFound, ProtectorError.keyUnavailable, ProtectorError.dataCorrupted, ProtectorError.secureEnclaveUnavailable,
             VaultError.corrupted, VaultError.unsupportedVersion, VaultError.protectorMismatch: .cannotOpen
        default: .failed(ErrorText.message(for: error))
        }
    }

    /// Fresh Touch ID / password check for sensitive actions.
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

    private func startOrphanCleanup(generation: Int) {
        guard let store else { return }
        Task.detached(priority: .background) {
            // Silent on purpose: never a dialog, never blocks.
            _ = try? await store.removeOrphanedKeyMaterial(alsoCheck: [KeychainProtector()])
        }
    }

    // MARK: Protection

    private func refreshProtection() async {
        guard let store else { return }
        appLockRequired = await store.requiresAppAuthentication
        switch await store.protectorIdentifier {
        case "secure-enclave": protection = .secureEnclave
        case "keychain": protection = .keychain
        default: protection = .unknown
        }
    }

    var secureEnclaveAvailable: Bool { SecureEnclaveProtector.isAvailable }

    /// What the vault really does (not what was asked for).
    var effectiveRequireAuth: Bool {
        switch protection {
        case .secureEnclave: true
        case .keychain, .unknown: appLockRequired
        }
    }

    /// Turns "ask for Touch ID / password" on or off. It lives in the vault, not in the preferences: on a Mac with
    /// Secure Enclave it decides the protector (Enclave = asks, keychain = does not), without one it is the sealed
    /// app-lock flag in the vault header. Lowering needs a fresh authentication first.
    func setRequireAuth(_ on: Bool) async {
        guard let store, phase == .unlocked else { return }
        let t = ticket
        if !on, AppPolicy.requiresFreshAuthentication(.requireAuthentication(from: effectiveRequireAuth, to: false)) {
            guard await authenticate(reason: String(localized: "Schutz des Tresors ändern")), isCurrent(t) else { return }
        }
        do {
            if secureEnclaveAvailable {
                let wanted: Protection = on ? .secureEnclave : .keychain
                if protection != wanted {
                    let protector: any KeyProtector = on ? SecureEnclaveProtector(context: Self.makeContext()) : KeychainProtector()
                    try await store.changeProtector(to: protector, requireAppAuthentication: on)
                } else if protection == .keychain {
                    try await store.setRequiresAppAuthentication(on)
                }
            } else {
                try await store.setRequiresAppAuthentication(on)
            }
        } catch {
            if isCurrent(t) {
                alert = AppAlert(title: String(localized: "Einstellung nicht geändert"), message: ErrorText.message(for: error))
            }
        }
        await refreshProtection()
        if protection == .secureEnclave { offerEnclaveUpgrade = false }
    }

    /// The offered upgrade after a restore: Secure Enclave protection, after the usual authentication.
    func upgradeToEnclave() async {
        await setRequireAuth(true)
    }

    func dismissEnclaveOffer() { offerEnclaveUpgrade = false }

    /// Applies a security setting; lowering protection first needs a fresh authentication.
    func applySecuritySetting(_ change: SecuritySettingChange, apply: @escaping () -> Void) async {
        guard phase == .unlocked else { return }
        let t = ticket
        if AppPolicy.requiresFreshAuthentication(change) {
            guard await authenticate(reason: String(localized: "Schutz von MacAuth ändern")), isCurrent(t) else { return }
        }
        apply()
    }

    // MARK: Global shortcut

    @ObservationIgnored private let hotKey = HotKeyService()

    /// Registers or removes the global shortcut according to the settings. Sets `hotKeyError` in plain words.
    func applyHotKey() {
        hotKeyError = nil
        guard settings.hotKeyEnabled else { hotKey.unregister(); return }
        guard settings.hotKeyCode >= 0 else {
            hotKey.unregister()
            hotKeyError = String(localized: "Nimm zuerst eine Tastenkombination auf.")
            return
        }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(settings.hotKeyModifiers))
        switch hotKey.register(keyCode: UInt32(settings.hotKeyCode), modifiers: flags, onPress: { [weak self] in self?.hotKeyPressed() }) {
        case .success: break
        case .failure(.needsModifier):
            hotKeyError = String(localized: "Die Kombination braucht mindestens ⌘, ⌥ oder ⌃.")
        case .failure(.taken):
            hotKeyError = String(localized: "Diese Kombination wird schon von einer anderen App oder vom System benutzt. Wähle eine andere.")
        case .failure(.other):
            hotKeyError = String(localized: "Die Tastenkombination konnte nicht angemeldet werden.")
        }
    }

    func pauseHotKey() { hotKey.unregister() }

    /// Shortcut pressed: bring the window forward (search focused, unlock prompt if locked); pressed again: hide.
    func hotKeyPressed() {
        if NSApp.isActive, !NSApp.isHidden, mainWindow?.isVisible == true, mainWindow?.isKeyWindow == true {
            NSApp.hide(nil)
            return
        }
        NSApp.unhide(nil)
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
        userRequestedShow()
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.title == "MacAuth" && !($0 is NSPanel) } ?? NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }
    }

    /// `--demo`: proves registration and the "already taken" detection, printed to stdout (not the system log).
    func demoHotKeySelfTest() {
        func say(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
        let flags: NSEvent.ModifierFlags = [.control, .option, .command]
        let code = UInt32(kVK_ANSI_M)
        func failure(_ result: Result<Void, HotKeyService.Failure>) -> HotKeyService.Failure? {
            if case .failure(let f) = result { f } else { nil }
        }
        let first = failure(hotKey.register(keyCode: code, modifiers: flags, onPress: {}))
        say("HotKey ⌃⌥⌘M: \(first == nil ? "registriert" : "Fehler \(first!)")")
        let other = HotKeyService(signature: "MAU2")
        let second = failure(other.register(keyCode: code, modifiers: flags, onPress: {}))
        say("HotKey zweite Anmeldung derselben Kombination: \(second == .taken ? "abgelehnt, belegt (Hinweis im Dialog: andere Kombination wählen)" : "unerwartet \(String(describing: second))")")
        let bare = failure(other.register(keyCode: code, modifiers: [.shift], onPress: {}))
        say("HotKey nur ⇧ ohne ⌘/⌥/⌃: \(bare == .needsModifier ? "abgelehnt (braucht Modifikator)" : "unerwartet \(String(describing: bare))")")
        other.unregister()
        hotKey.unregister()
        say("HotKey wieder entfernt: \(hotKey.isRegistered ? "nein" : "ja")")
    }

    // MARK: Rescue (vault cannot be opened)

    func rescueEntries() async -> [RescueEntry] {
        guard let store else { return demoRescue }
        var entries: [RescueEntry] = []
        if await store.hasPreviousGeneration {
            let date = (try? FileManager.default.attributesOfItem(atPath: store.previousURL.path)[.modificationDate] as? Date) ?? .distantPast
            entries.append(RescueEntry(id: "previous", kind: .previous, date: date, protector: nil))
        }
        for file in await store.replacedFiles() {
            entries.append(RescueEntry(id: file.url.lastPathComponent, kind: .replaced(file), date: file.date, protector: file.protectorIdentifier))
        }
        return entries
    }

    /// Brings a file back, then offers the normal unlock (the user pressed the button).
    func restore(_ entry: RescueEntry) async -> Bool {
        guard let store, phase == .locked else { return false }
        let t = ticket
        do {
            switch entry.kind {
            case .previous: try await store.recoverPreviousGeneration()
            case .replaced(let file): try await store.restoreReplaced(file)
            case .demo: return false
            }
        } catch {
            if isCurrent(t) { alert = AppAlert(title: String(localized: "Wiederherstellen nicht möglich"), message: ErrorText.message(for: error)) }
            await store.lock()
            return false
        }
        guard isCurrent(t) else { return false }
        hasPreviousGeneration = await store.hasPreviousGeneration
        await refreshProtection()
        lockNotice = nil
        sheet = nil
        await unlock()
        if phase == .unlocked, protection == .keychain, secureEnclaveAvailable { offerEnclaveUpgrade = true }
        return true
    }

    // MARK: Persistence

    private var vaultData: VaultData { VaultData(accounts: accounts, groups: groups) }

    /// The complete current vault (for exports).
    var currentVault: VaultData { vaultData }

    /// A backup was written. The reminder is reset only if the file holds exactly the current, non-empty vault.
    func backupWritten(_ exported: VaultData) -> Bool {
        guard phase == .unlocked, AppPolicy.backupCoversCurrent(exported: exported, current: vaultData) else { return false }
        settings.lastBackupExport = Date().timeIntervalSince1970
        return true
    }

    /// Newest state wins: older queued saves skip themselves; a lock writes whatever is still unsaved.
    private func persist() {
        settings.lastAccountChange = Date().timeIntervalSince1970
        saveSeq += 1
        guard let store else { savedSeq = saveSeq; return }
        let seq = saveSeq
        let data = vaultData
        let generation = epoch.generation
        Task { [weak self] in
            guard let self, self.epoch.isCurrent(generation), seq == self.saveSeq else { return }
            do {
                try await store.save(data)
                if self.epoch.isCurrent(generation) { self.savedSeq = max(self.savedSeq, seq) }
            } catch {
                guard self.epoch.isCurrent(generation) else { return }
                self.alert = AppAlert(title: String(localized: "Speichern fehlgeschlagen"), message: ErrorText.message(for: error))
            }
        }
    }

    /// Creates the vault (first start, or the confirmed replacement) with the given content.
    private func createVault(_ data: VaultData, replacing: Bool) async -> Bool {
        guard let store else { return false }
        let generation = epoch.generation
        do {
            let protector: any KeyProtector = SecureEnclaveProtector.isAvailable
                ? SecureEnclaveProtector(context: Self.makeContext()) : KeychainProtector()
            try await store.create(contents: data, protector: protector, replacingExisting: replacing, requireAppAuthentication: true)
            await refreshProtection()
            guard epoch.isCurrent(generation) else {
                await store.lock()   // locked while creating: the vault exists, but nothing is shown
                phase = .locked
                return false
            }
            accounts = data.accounts
            groups = data.groups
            settings.lastAccountChange = Date().timeIntervalSince1970
            phase = .unlocked
            lockNotice = nil
            hasPreviousGeneration = await store.hasPreviousGeneration
            startAutoLock()
            normalizeSelection()
            focusSearch()
            return true
        } catch {
            if epoch.isCurrent(generation) {
                alert = AppAlert(title: String(localized: "Tresor konnte nicht angelegt werden"), message: ErrorText.message(for: error))
            }
            return false
        }
    }

    // MARK: Accounts

    func nextSortIndex() -> Int { (accounts.map(\.sortIndex).max() ?? -1) + 1 }

    /// Adds one account (manual form). On first start this creates the vault.
    func add(_ account: Account, ticket t: Ticket) async -> Bool {
        guard isCurrent(t) else { return false }
        var account = account
        account.sortIndex = nextSortIndex()
        if phase == .firstRun {
            return await createVault(VaultData(accounts: [account], groups: groups), replacing: false)
        }
        guard phase == .unlocked else { return false }
        accounts.append(account)
        persist()
        return true
    }

    func update(_ account: Account) {
        guard phase == .unlocked, let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        persist()
    }

    func delete(_ id: UUID) {
        guard phase == .unlocked else { return }
        accounts.removeAll { $0.id == id }
        persist()
        normalizeSelection()
    }

    func togglePin(_ id: UUID) {
        guard phase == .unlocked, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].pinned.toggle()
        persist()
    }

    func move(_ id: UUID, to groupID: UUID?) {
        guard phase == .unlocked, let index = accounts.firstIndex(where: { $0.id == id }), accounts[index].groupID != groupID else { return }
        accounts[index].groupID = groupID
        persist()
    }

    /// Puts `id` in front of `target` in the custom order.
    func reorder(_ id: UUID, before target: UUID) {
        guard phase == .unlocked, id != target else { return }
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
        guard phase == .unlocked, let index = accounts.firstIndex(where: { $0.id == id }), accounts[index].kind == .hotp else { return }
        accounts[index].advanceCounter()
        persist()
    }

    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }

    func group(_ id: UUID?) -> AccountGroup? { id.flatMap { id in groups.first { $0.id == id } } }

    // MARK: Groups

    func addGroup(_ group: AccountGroup) {
        guard phase == .unlocked || phase == .firstRun else { return }
        groups.append(group)
        if phase == .unlocked { persist() }
    }

    func updateGroup(_ group: AccountGroup) {
        guard phase == .unlocked, let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index] = group
        persist()
    }

    func deleteGroup(_ id: UUID) {
        guard phase == .unlocked else { return }
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

    /// Picks the first visible card without counting as a user choice.
    func autoSelectFirst() {
        settingSelectionAutomatically = true
        selection = visibleAccounts.first?.id
        settingSelectionAutomatically = false
        selectionExplicit = false
    }

    func normalizeSelection() {
        let visible = visibleAccounts
        if let selection, visible.contains(where: { $0.id == selection }) { return }
        autoSelectFirst()
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
        selectionExplicit = true
    }

    func focusSearch() { focusSearchTick += 1 }

    // MARK: Copying

    func copy(_ id: UUID?, next: Bool = false) {
        guard phase == .unlocked, let id, let account = account(id) else { return }
        let now = Date()
        guard let code = try? (next ? account.nextCode(at: now) : account.code(at: now)) else { return }
        ClipboardService.shared.copy(code, clearAfter: settings.clipboardClearSeconds)
        if next, account.kind == .hotp { advanceHOTP(id) }
        selection = id
        copiedID = id
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
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

    func makeSession(source: ImportSession.Source, delivery: ImportSession.Delivery, accounts found: [Account],
                     skipped: [String] = [], groups incoming: [AccountGroup] = [], intent: ImportIntent? = nil,
                     format: ImportFormat? = nil, rowsWithoutCode: Int = 0) -> ImportSession {
        let defaultGroup = UUID(uuidString: settings.defaultGroupID).flatMap { id in groups.contains { $0.id == id } ? id : nil }
        let resolved: ImportIntent
        if let intent {
            resolved = intent
        } else {
            switch phase {
            case .unlocked: resolved = .addToUnlocked(generation: epoch.generation)
            case .firstRun: resolved = .createVault
            default: resolved = .addToUnlocked(generation: -1)   // can never commit
            }
        }
        return ImportSession(source: source, delivery: delivery, intent: resolved, accounts: found, skipped: skipped,
                             existing: phase == .unlocked ? accounts : [],
                             existingGroups: phase == .locked ? [] : groups, incomingGroups: incoming, defaultGroupID: defaultGroup,
                             format: format, rowsWithoutCode: rowsWithoutCode)
    }

    /// Stores the confirmed rows according to the session's intent.
    func commit(_ session: ImportSession) async -> Bool {
        guard AppPolicy.canCommit(session.intent, phase: phase, generation: epoch.generation, replaceConfirmed: session.replaceConfirmed) else {
            return false
        }
        let chosen = session.rows.filter(\.include)
        guard !chosen.isEmpty else { return false }
        let used = Set(chosen.compactMap(\.groupID))
        let incomingGroups = session.availableGroups.filter { used.contains($0.id) }
        let added = chosen.map { row -> Account in
            var account = row.account
            account.groupID = row.groupID
            return account
        }
        let ok: Bool
        switch session.intent {
        case .addToUnlocked:
            let merged = vaultData.merging(accounts: added, groups: incomingGroups)
            accounts = merged.accounts
            groups = merged.groups
            persist()
            ok = true
        case .createVault:
            let merged = VaultData(accounts: [], groups: groups).merging(accounts: added, groups: incomingGroups)
            ok = await createVault(merged, replacing: false)
        case .replaceVault:
            let merged = VaultData(accounts: [], groups: []).merging(accounts: added, groups: incomingGroups)
            ok = await createVault(merged, replacing: true)
        }
        if ok { announceCleanup(for: session.delivery) }
        return ok
    }

    private func announceCleanup(for delivery: ImportSession.Delivery) {
        switch delivery {
        case .image:
            alert = AppAlert(title: String(localized: "Screenshot jetzt löschen"),
                             message: String(localized: "Lösche den Screenshot jetzt, auch aus dem Papierkorb und aus iCloud-Fotos. Er enthält alle Schlüssel."))
        case .file:
            alert = AppAlert(title: String(localized: "Exportdatei jetzt löschen"),
                             message: String(localized: "Lösche die Exportdatei jetzt, auch aus dem Papierkorb und aus iCloud Drive. Sie enthält alle Schlüssel im Klartext."))
        case .passwordFile:
            alert = AppAlert(title: String(localized: "Exportdatei jetzt löschen"),
                             message: String(localized: "Lösche die Datei jetzt, auch aus dem Papierkorb und aus iCloud Drive. Sie enthält alle deine Passwörter und alle Schlüssel im Klartext."))
        case .camera, .text, .backup:
            break
        }
    }
}
