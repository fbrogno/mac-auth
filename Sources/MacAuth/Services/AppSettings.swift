import AuthCore
import Foundation
import Observation

/// User preferences (never secrets). Stored in `UserDefaults`; the demo renderer passes an ephemeral suite.
///
/// The four security settings (auto-lock, screen protection, hidden codes, clipboard clearing) are NOT preferences:
/// they live in the encrypted vault (`VaultData.security`) because the preferences file can be edited without any
/// authentication. Here they are held in memory only: strict defaults while locked, the vault's values while unlocked.
@MainActor @Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let domain: String

    /// What applies right now. Set by the model from the vault after unlocking and reset to `.strict` on lock.
    var security: SecuritySettings = .strict

    /// Minutes of inactivity before locking; 0 = never.
    var autoLockMinutes: Int {
        get { security.autoLockMinutes }
        set { security.autoLockMinutes = newValue }
    }
    /// Seconds until the clipboard is cleared; 0 = never.
    var clipboardClearSeconds: Int {
        get { security.clipboardClearSeconds }
        set { security.clipboardClearSeconds = newValue }
    }
    var hideAfterCopy: Bool { didSet { defaults.set(hideAfterCopy, forKey: "hideAfterCopy") } }
    var protectScreen: Bool {
        get { security.protectScreen }
        set { security.protectScreen = newValue }
    }
    var hideCodes: Bool {
        get { security.hideCodes }
        set { security.hideCodes = newValue }
    }
    /// Group preselected when importing; empty = none.
    var defaultGroupID: String { didSet { defaults.set(defaultGroupID, forKey: "defaultGroupID") } }
    var backupReminder: Bool { didSet { defaults.set(backupReminder, forKey: "backupReminder") } }
    var listMode: Bool { didSet { defaults.set(listMode, forKey: "listMode") } }
    /// Quick access panel (global shortcut and optional menu bar item). Off by default; nothing is registered until the
    /// user switches it on. These are ordinary preferences: they lower no protection.
    var quickAccessEnabled: Bool { didSet { defaults.set(quickAccessEnabled, forKey: "quickAccessEnabled") } }
    /// Virtual key code, -1 = none recorded.
    var quickAccessKeyCode: Int { didSet { defaults.set(quickAccessKeyCode, forKey: "quickAccessKeyCode") } }
    /// `NSEvent.ModifierFlags` raw value (device-independent bits only).
    var quickAccessModifiers: Int { didSet { defaults.set(quickAccessModifiers, forKey: "quickAccessModifiers") } }
    var quickAccessLabel: String { didSet { defaults.set(quickAccessLabel, forKey: "quickAccessLabel") } }
    /// Menu bar item that opens the panel. Off by default.
    var menuBarItem: Bool { didSet { defaults.set(menuBarItem, forKey: "menuBarItem") } }
    /// Seconds since 1970; 0 = never.
    var lastBackupExport: Double { didSet { defaults.set(lastBackupExport, forKey: "lastBackupExport") } }
    var lastAccountChange: Double { didSet { defaults.set(lastAccountChange, forKey: "lastAccountChange") } }

    private static let legacyHotKeyKeys = ["hotKeyEnabled", "hotKeyCode", "hotKeyModifiers", "hotKeyLabel"]
    private static let legacyKeys = ["autoLockMinutes", "protectScreen", "hideCodes", "clipboardClearSeconds"]

    /// The values 1.0.0 kept in the preferences file (only those actually stored). Read from the app's persistent
    /// domain, like everything else. Used once, for the migration into the vault.
    func legacySecurityValues() -> SecuritySettings.Legacy {
        let stored = defaults.persistentDomain(forName: domain) ?? [:]
        return SecuritySettings.Legacy(autoLockMinutes: stored["autoLockMinutes"] as? Int, protectScreen: stored["protectScreen"] as? Bool,
                                       hideCodes: stored["hideCodes"] as? Bool, clipboardClearSeconds: stored["clipboardClearSeconds"] as? Int)
    }

    /// Removes the old keys, after their (stricter-or-equal) values are safely stored in the vault.
    func removeLegacySecurityValues() {
        for key in Self.legacyKeys { defaults.removeObject(forKey: key) }
    }

    /// Preferences are read ONLY from the app's persistent domain. `UserDefaults.object(forKey:)` would also
    /// return values from the command line (`-autoLockMinutes 0`, `-protectScreen NO`) and from the global
    /// domain; the persistent domain contains only what the app itself saved.
    /// Whether the vault asks for Touch ID / password is not a preference: it lives in the authenticated vault
    /// header (`VaultStore.requiresAppAuthentication`).
    init(defaults: UserDefaults = .standard, domain: String = Bundle.main.bundleIdentifier ?? "com.fbrogno.macauth") {
        self.defaults = defaults
        self.domain = domain
        let stored = defaults.persistentDomain(forName: domain) ?? [:]
        func bool(_ key: String, _ fallback: Bool) -> Bool { stored[key] as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { stored[key] as? Int ?? fallback }
        hideAfterCopy = bool("hideAfterCopy", false)
        defaultGroupID = stored["defaultGroupID"] as? String ?? ""
        backupReminder = bool("backupReminder", true)
        listMode = bool("listMode", false)
        quickAccessEnabled = bool("quickAccessEnabled", false)
        quickAccessKeyCode = int("quickAccessKeyCode", -1)
        quickAccessModifiers = int("quickAccessModifiers", 0)
        quickAccessLabel = stored["quickAccessLabel"] as? String ?? ""
        menuBarItem = bool("menuBarItem", false)
        lastBackupExport = stored["lastBackupExport"] as? Double ?? 0
        lastAccountChange = stored["lastAccountChange"] as? Double ?? 0

    }

    /// The former option "global shortcut shows or hides the window" is replaced by the quick access: an enabled
    /// shortcut moves over with the same keys, then the old keys are removed (also if nothing moves). This WRITES
    /// preferences, so it runs only in the normal start (`AppModel.init`), never in the read-only `--print-settings`.
    func migrateLegacyHotKey() {
        let stored = defaults.persistentDomain(forName: domain) ?? [:]
        let legacy = QuickAccessShortcut.Legacy(enabled: stored["hotKeyEnabled"] as? Bool, keyCode: stored["hotKeyCode"] as? Int,
                                                modifiers: stored["hotKeyModifiers"] as? Int, label: stored["hotKeyLabel"] as? String)
        if let migrated = QuickAccessShortcut.migrate(legacy: legacy, alreadyStored: stored["quickAccessEnabled"] != nil) {
            quickAccessEnabled = migrated.enabled
            quickAccessKeyCode = migrated.keyCode
            quickAccessModifiers = migrated.modifiers
            quickAccessLabel = migrated.label
            defaults.set(migrated.enabled, forKey: "quickAccessEnabled")
            defaults.set(migrated.keyCode, forKey: "quickAccessKeyCode")
            defaults.set(migrated.modifiers, forKey: "quickAccessModifiers")
            defaults.set(migrated.label, forKey: "quickAccessLabel")
        }
        for key in Self.legacyHotKeyKeys { defaults.removeObject(forKey: key) }
    }

    /// True if accounts changed after the last exported backup.
    func needsBackup(hasAccounts: Bool) -> Bool {
        backupReminder && hasAccounts && lastAccountChange > lastBackupExport
    }
}

/// `MacAuth --print-settings [-key value ...]`: prints what a naive `UserDefaults` read and `AppSettings` return,
/// to show that command-line values never reach the settings. Starts no window and touches no vault: the security
/// settings come from the vault, so without an unlocked vault the strict defaults are what applies.
@MainActor
enum SettingsProbe {
    static func run() {
        let defaults = UserDefaults.standard
        let settings = AppSettings()
        func say(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
        let source = "(Quelle: Tresor; gesperrt gelten die strengen Standardwerte)"
        let rows: [(String, Any?, Any)] = [
            ("autoLockMinutes", defaults.object(forKey: "autoLockMinutes"), "\(settings.autoLockMinutes) \(source)"),
            ("protectScreen", defaults.object(forKey: "protectScreen"), "\(settings.protectScreen) \(source)"),
            ("hideCodes", defaults.object(forKey: "hideCodes"), "\(settings.hideCodes) \(source)"),
            ("clipboardClearSeconds", defaults.object(forKey: "clipboardClearSeconds"), "\(settings.clipboardClearSeconds) \(source)"),
            ("quickAccessEnabled", defaults.object(forKey: "quickAccessEnabled"), settings.quickAccessEnabled),
            ("requireAuth", defaults.object(forKey: "requireAuth"), "(keine Einstellung mehr, steht im Tresor-Kopf)"),
        ]
        for (key, naive, actual) in rows {
            say("\(key): UserDefaults liefert \(naive.map { "\($0)" } ?? "nichts"), AppSettings nutzt \(actual)")
        }
    }
}
