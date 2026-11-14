import Foundation
import Observation

/// User preferences (never secrets). Stored in `UserDefaults`; the demo renderer passes an ephemeral suite.
@MainActor @Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    /// Minutes of inactivity before locking; 0 = never.
    var autoLockMinutes: Int { didSet { defaults.set(autoLockMinutes, forKey: "autoLockMinutes") } }
    /// Seconds until the clipboard is cleared; 0 = never.
    var clipboardClearSeconds: Int { didSet { defaults.set(clipboardClearSeconds, forKey: "clipboardClearSeconds") } }
    var hideAfterCopy: Bool { didSet { defaults.set(hideAfterCopy, forKey: "hideAfterCopy") } }
    var protectScreen: Bool { didSet { defaults.set(protectScreen, forKey: "protectScreen") } }
    var hideCodes: Bool { didSet { defaults.set(hideCodes, forKey: "hideCodes") } }
    /// Group preselected when importing; empty = none.
    var defaultGroupID: String { didSet { defaults.set(defaultGroupID, forKey: "defaultGroupID") } }
    var backupReminder: Bool { didSet { defaults.set(backupReminder, forKey: "backupReminder") } }
    var listMode: Bool { didSet { defaults.set(listMode, forKey: "listMode") } }
    /// Optional system-wide shortcut that shows or hides the window. Off by default.
    var hotKeyEnabled: Bool { didSet { defaults.set(hotKeyEnabled, forKey: "hotKeyEnabled") } }
    /// Virtual key code, -1 = none recorded.
    var hotKeyCode: Int { didSet { defaults.set(hotKeyCode, forKey: "hotKeyCode") } }
    /// `NSEvent.ModifierFlags` raw value (device-independent bits only).
    var hotKeyModifiers: Int { didSet { defaults.set(hotKeyModifiers, forKey: "hotKeyModifiers") } }
    var hotKeyLabel: String { didSet { defaults.set(hotKeyLabel, forKey: "hotKeyLabel") } }
    /// Seconds since 1970; 0 = never.
    var lastBackupExport: Double { didSet { defaults.set(lastBackupExport, forKey: "lastBackupExport") } }
    var lastAccountChange: Double { didSet { defaults.set(lastAccountChange, forKey: "lastAccountChange") } }

    /// Preferences are read ONLY from the app's persistent domain. `UserDefaults.object(forKey:)` would also
    /// return values from the command line (`-autoLockMinutes 0`, `-protectScreen NO`) and from the global
    /// domain; the persistent domain contains only what the app itself saved.
    /// Whether the vault asks for Touch ID / password is not a preference: it lives in the authenticated vault
    /// header (`VaultStore.requiresAppAuthentication`).
    init(defaults: UserDefaults = .standard, domain: String = Bundle.main.bundleIdentifier ?? "com.fbrogno.macauth") {
        self.defaults = defaults
        let stored = defaults.persistentDomain(forName: domain) ?? [:]
        func bool(_ key: String, _ fallback: Bool) -> Bool { stored[key] as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { stored[key] as? Int ?? fallback }
        autoLockMinutes = int("autoLockMinutes", 5)
        clipboardClearSeconds = int("clipboardClearSeconds", 30)
        hideAfterCopy = bool("hideAfterCopy", false)
        protectScreen = bool("protectScreen", true)
        hideCodes = bool("hideCodes", false)
        defaultGroupID = stored["defaultGroupID"] as? String ?? ""
        backupReminder = bool("backupReminder", true)
        listMode = bool("listMode", false)
        hotKeyEnabled = bool("hotKeyEnabled", false)
        hotKeyCode = int("hotKeyCode", -1)
        hotKeyModifiers = int("hotKeyModifiers", 0)
        hotKeyLabel = stored["hotKeyLabel"] as? String ?? ""
        lastBackupExport = stored["lastBackupExport"] as? Double ?? 0
        lastAccountChange = stored["lastAccountChange"] as? Double ?? 0
    }

    /// True if accounts changed after the last exported backup.
    func needsBackup(hasAccounts: Bool) -> Bool {
        backupReminder && hasAccounts && lastAccountChange > lastBackupExport
    }
}

/// `MacAuth --print-settings [-key value ...]`: prints what a naive `UserDefaults` read and `AppSettings` return,
/// to show that command-line values never reach the settings. Starts no window and touches no vault.
@MainActor
enum SettingsProbe {
    static func run() {
        let defaults = UserDefaults.standard
        let settings = AppSettings()
        func say(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
        let rows: [(String, Any?, Any)] = [
            ("autoLockMinutes", defaults.object(forKey: "autoLockMinutes"), settings.autoLockMinutes),
            ("protectScreen", defaults.object(forKey: "protectScreen"), settings.protectScreen),
            ("hideCodes", defaults.object(forKey: "hideCodes"), settings.hideCodes),
            ("clipboardClearSeconds", defaults.object(forKey: "clipboardClearSeconds"), settings.clipboardClearSeconds),
            ("hotKeyEnabled", defaults.object(forKey: "hotKeyEnabled"), settings.hotKeyEnabled),
            ("requireAuth", defaults.object(forKey: "requireAuth"), "(keine Einstellung mehr, steht im Tresor-Kopf)"),
        ]
        for (key, naive, actual) in rows {
            say("\(key): UserDefaults liefert \(naive.map { "\($0)" } ?? "nichts"), AppSettings nutzt \(actual)")
        }
    }
}
