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
    /// Why the quick access shortcut is not registered (plain words), shown in the settings.
    var quickAccessError: String?
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
    /// Set by a successful system authentication on the lock screen; every recovery needs it (see `authorizeRecovery`).
    @ObservationIgnored private var recovery = RecoveryAuthorization()
    @ObservationIgnored private let store: VaultStore?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var saveSeq = 0
    @ObservationIgnored private var savedSeq = 0
    /// `lastUsedAt` was noted in memory (a copy) and is not in the vault file yet. Written with the next real change,
    /// or when the vault locks / the app quits (`AppPolicy.exitWrite`), never as a change of its own.
    @ObservationIgnored private var usageDirty = false
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var settingSelectionAutomatically = false
    @ObservationIgnored private var lockObserver: SystemLockObserver?
    @ObservationIgnored private var autoLockTimer: Timer?
    @ObservationIgnored private var copiedTask: Task<Void, Never>?
    @ObservationIgnored private var keepAliveSince: Date?
    @ObservationIgnored private let demoRescue: [RescueEntry]

    init(settings: AppSettings? = nil) {
        let resolved = settings ?? AppSettings()
        if settings == nil { resolved.migrateLegacyHotKey() }   // normal start only; `--print-settings` must not write
        self.settings = resolved
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
        quick.apply()
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeBeforeQuit() }
        }
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
            var authenticated = false
            let protector: any KeyProtector
            switch identifier {
            case "secure-enclave":
                protector = SecureEnclaveProtector(context: Self.makeContext())
            case "keychain":
                if await store.requiresAppAuthentication {
                    // Only the user's own cancel is "cancelled"; any other failure must reach the screen that offers the
                    // recovery options (restore from backup), so it is reported as a failure.
                    switch await authenticateOutcome(reason: String(localized: "MacAuth entsperren")) {
                    case .success, .noPasscode: authenticated = true
                    case .cancelled:
                        if epoch.isCurrent(generation) { lockNotice = .cancelled }
                        return
                    case .failed:
                        if epoch.isCurrent(generation) { lockNotice = .failed(String(localized: "Die Abfrage mit Touch ID oder Passwort ist fehlgeschlagen.")) }
                        return
                    }
                }
                protector = KeychainProtector()
            default:
                lockNotice = .cannotOpen
                return
            }
            var data = try await store.unlock(using: protector, appAuthenticated: authenticated)
            data = await migratingLegacySettings(in: data, store: store)
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

    /// One-time migration of the old preferences-file values into the vault (1.0.0 kept them unauthenticated): an old
    /// value is adopted only if it is at least as strict as the default. The old keys are removed once the vault
    /// holds the result; if saving fails they stay and the next unlock tries again.
    private func migratingLegacySettings(in data: VaultData, store: VaultStore) async -> VaultData {
        let legacy = settings.legacySecurityValues()
        guard !legacy.isEmpty else { return data }
        var result = data
        if let migrated = VaultData.settingsToMigrate(vault: data.security, legacy: legacy) {
            result.security = migrated
            do { try await store.save(result) } catch { return data }
        }
        settings.removeLegacySecurityValues()
        return result
    }

    private func show(_ data: VaultData) {
        settings.security = data.security ?? .strict
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
        let write = wasUnlocked ? AppPolicy.exitWrite(unsavedChange: savedSeq != saveSeq, unsavedUsage: usageDirty) : .nothing
        let unsaved: VaultData? = write == .nothing ? nil : storedVault
        usageDirty = false
        // While locked the strict defaults apply (screen protection on, shortest auto-lock, ...).
        settings.security = .strict
        autoLockTimer?.invalidate()
        autoLockTimer = nil
        keepAliveSince = nil
        sheet = nil
        alert = nil
        FilePanels.cancelAll()   // no open/save panel stays over the lock screen
        quick.vaultDidLock()     // the quick access panel drops its content and closes
        recovery.consume()
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
                if write == .usageOnly {
                    try? await store?.saveUsage(unsaved)   // silent: a note about a copy is not worth a warning
                } else {
                    do { try await store?.save(unsaved) } catch {
                        // Locking still happens; the lock screen says plainly that the last change was not written.
                        self?.lockWarning = String(localized: "Die letzte Änderung konnte nicht gespeichert werden: \(ErrorText.message(for: error))")
                    }
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

    /// Whether a user action (shortcut, menu bar click) may start the unlock prompt right now: after the user's own
    /// cancel or no failure at all, never after "cannot open" or other failures (those need the main window).
    var noticeAllowsUnlockPrompt: Bool { lockNotice == nil || lockNotice == .cancelled }

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

    /// Touch ID / password check without any dialog of its own; the caller decides what each outcome means.
    func authenticateOutcome(reason: String) async -> AuthOutcome {
        if isDemo { return .success }
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .success : .failed
        } catch let error as LAError {
            return AuthOutcome.from(error.code)
        } catch {
            return .failed
        }
    }

    /// Fresh Touch ID / password check for sensitive actions. A Mac without login password passes (the check cannot
    /// ask anything); exports, QR transfer and backups use `authenticateForExport`, which says so first.
    func authenticate(reason: String) async -> Bool {
        switch await authenticateOutcome(reason: reason) {
        case .success, .noPasscode: return true
        case .cancelled: return false
        case .failed:
            alert = AppAlert(title: String(localized: "Authentifizierung nicht möglich"),
                             message: String(localized: "Die Abfrage mit Touch ID oder Passwort ist fehlgeschlagen."))
            return false
        }
    }

    /// Like `authenticate`, for actions that take secrets out of the app (backup, plain-text export, QR transfer).
    /// On a Mac without login password nothing protects the action, so the user has to confirm that explicitly.
    func authenticateForExport(reason: String) async -> Bool {
        let t = ticket
        switch await authenticateOutcome(reason: reason) {
        case .success: return true
        case .cancelled: return false
        case .failed:
            alert = AppAlert(title: String(localized: "Authentifizierung nicht möglich"),
                             message: String(localized: "Die Abfrage mit Touch ID oder Passwort ist fehlgeschlagen."))
            return false
        case .noPasscode:
            guard isCurrent(t) else { return false }
            let box = NSAlert()
            box.alertStyle = .warning
            box.messageText = String(localized: "Dieser Mac hat kein Anmeldepasswort")
            box.informativeText = String(localized: "Ohne Anmeldepasswort schützt nichts diesen Export: Wer an diesem Mac sitzt, erhält damit alle Schlüssel deiner Konten. Lege in den Systemeinstellungen ein Anmeldepasswort fest. Willst du trotzdem fortfahren?")
            let cancel = box.addButton(withTitle: String(localized: "Abbrechen"))
            cancel.keyEquivalent = "\r"
            box.addButton(withTitle: String(localized: "Trotzdem fortfahren")).keyEquivalent = ""
            let proceed = box.runModal() == .alertSecondButtonReturn
            return proceed && isCurrent(t)
        }
    }

    // MARK: Recovery from the lock screen

    /// Every recovery from the lock screen (earlier version, set-aside file, previous generation, backup file) first
    /// needs a successful system authentication: a vault file written while the unlock prompt was off must not turn
    /// the lock screen into a way in. Works with the login password even if the Secure Enclave key is lost.
    func authorizeRecovery() async -> Bool {
        guard phase == .locked else { return false }
        let t = ticket
        guard await authenticate(reason: String(localized: "Tresor wiederherstellen")), isCurrent(t) else { return false }
        recovery.grant(generation: epoch.generation)
        return true
    }

    /// Opens a recovery sheet after the authentication.
    func beginRecovery(_ target: ActiveSheet) async {
        guard await authorizeRecovery() else { return }
        sheet = target
    }

    private func recoveryPermitted() async -> Bool {
        if recovery.permits(generation: epoch.generation) { return true }
        return await authorizeRecovery()
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
        persist(accountsChanged: false)   // these settings live in the vault, not in the preferences
    }

    // MARK: Quick access (global shortcut, menu bar item, panel)

    @ObservationIgnored private(set) lazy var quick = QuickAccessController(model: self)

    /// Registers or removes the shortcut and the menu bar item according to the settings.
    func applyQuickAccess() { quick.apply() }

    /// Switches the quick access on or off. Switching on without a recorded combination suggests ⌃⌥Space.
    func setQuickAccessEnabled(_ on: Bool) {
        if on, settings.quickAccessKeyCode < 0 {
            let suggestion = QuickAccessShortcut.suggestion
            settings.quickAccessKeyCode = suggestion.keyCode
            settings.quickAccessModifiers = suggestion.modifiers
            settings.quickAccessLabel = suggestion.label
        }
        settings.quickAccessEnabled = on
        quick.apply()
    }

    /// While the shortcut is being recorded it is unregistered, so the recording keys do not trigger it.
    func pauseQuickAccessShortcut() { quick.pauseShortcut() }

    /// `--demo`: proves registration and the "already taken" detection, printed to stdout (not the system log).
    func demoHotKeySelfTest() {
        func say(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
        let flags: NSEvent.ModifierFlags = [.control, .option, .command]
        let code = UInt32(kVK_ANSI_M)
        func failure(_ result: Result<Void, HotKeyService.Failure>) -> HotKeyService.Failure? {
            if case .failure(let f) = result { f } else { nil }
        }
        let hotKey = HotKeyService()
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
        guard await recoveryPermitted() else { return false }
        let t = ticket
        recovery.consume()
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

    /// Accounts and groups: what exports, backups and imports see. Never carries the security settings.
    private var vaultData: VaultData { VaultData(accounts: accounts, groups: groups) }

    /// What is written to the vault file: the above plus this device's security settings.
    private var storedVault: VaultData { VaultData(accounts: accounts, groups: groups, security: settings.security) }

    /// The complete current vault (for exports).
    var currentVault: VaultData { vaultData }

    /// A backup was written. The reminder is reset only if the file holds exactly the current, non-empty vault.
    func backupWritten(_ exported: VaultData) -> Bool {
        guard phase == .unlocked, AppPolicy.backupCoversCurrent(exported: exported, current: vaultData) else { return false }
        settings.lastBackupExport = Date().timeIntervalSince1970
        return true
    }

    /// Quit: writes a usage note that is still only in memory (or a real change still queued), without rotating the
    /// previous generation for the note. Waits briefly (the store is an actor; the main thread is not needed for it)
    /// and ignores failures: at quit there is nobody to tell, and the note is not a change.
    private func writeBeforeQuit() {
        guard phase == .unlocked, let store else { return }
        let write = AppPolicy.exitWrite(unsavedChange: savedSeq != saveSeq, unsavedUsage: usageDirty)
        guard write != .nothing else { return }
        let data = storedVault
        usageDirty = false
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            if write == .usageOnly { try? await store.saveUsage(data) } else { try? await store.save(data) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    /// Newest state wins: older queued saves skip themselves; a lock writes whatever is still unsaved.
    /// Every real change also carries a usage note that is still pending.
    private func persist(accountsChanged: Bool = true) {
        if accountsChanged { settings.lastAccountChange = Date().timeIntervalSince1970 }
        usageDirty = false
        saveSeq += 1
        guard let store else { savedSeq = saveSeq; return }
        let seq = saveSeq
        let data = storedVault
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
            settings.security = .strict   // a new vault starts with the strict defaults
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

    /// Applies the edit sheet's fields to the CURRENT account, so a counter or usage note that moved while the sheet
    /// was open is not overwritten by an old copy.
    func update(_ id: UUID, with edit: AccountEdit) {
        guard phase == .unlocked, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index] = accounts[index].applying(edit)
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
        guard let id, copyCode(id, next: next) else { return }
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

    /// The one place that puts a code on the clipboard (main window and quick access): concealed, current host only,
    /// cleared after the configured time. TOTP: the current or the next code. HOTP with `next`: the next code, and the
    /// counter moves on and is saved (the main window's "copy next code and count on"). Notes the use for the
    /// quick access order. Does nothing unless the vault is unlocked.
    @discardableResult
    private func copyCode(_ id: UUID, next: Bool) -> Bool {
        guard phase == .unlocked, let index = accounts.firstIndex(where: { $0.id == id }) else { return false }
        let account = accounts[index]
        let now = Date()
        guard let code = try? (next ? account.nextCode(at: now) : account.code(at: now)) else { return false }
        ClipboardService.shared.copy(code, clearAfter: settings.clipboardClearSeconds)
        let advanced = next && account.kind == .hotp
        if advanced { accounts[index].advanceCounter() }
        accounts[index].lastUsedAt = now
        if advanced {
            persist()   // the counter is a real change: saved at once (the note goes along)
        } else {
            usageDirty = true   // only noted in memory; written with the next change, at lock or at quit
        }
        return true
    }

    /// Quick access copy: only in the lock generation and phase the panel's list was built in, so a copy that was
    /// started before a lock never completes after it. No selection, toast or hiding of the main window.
    @discardableResult
    func copyFromQuickAccess(_ action: QuickAccess.CopyAction, ticket t: Ticket) -> Bool {
        guard isCurrent(t) else { return false }
        switch action {
        case .current(let id): return copyCode(id, next: false)
        case .next(let id): return copyCode(id, next: true)
        case .advancingHOTP(let id): return copyCode(id, next: true)
        }
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
        if session.intent == .replaceVault {
            guard await recoveryPermitted(),   // may ask the system once more; then the state is checked again
                  AppPolicy.canCommit(session.intent, phase: phase, generation: epoch.generation, replaceConfirmed: session.replaceConfirmed)
            else { return false }
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
            if ok { recovery.consume() }
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
