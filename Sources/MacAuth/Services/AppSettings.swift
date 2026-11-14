import Foundation
import Observation

/// User preferences (never secrets). Stored in `UserDefaults`; the demo renderer passes an ephemeral suite.
@MainActor @Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    /// Touch ID / password needed to unlock (Secure Enclave). Off: the vault key sits in the login keychain.
    var requireAuth: Bool { didSet { defaults.set(requireAuth, forKey: "requireAuth") } }
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
    /// Seconds since 1970; 0 = never.
    var lastBackupExport: Double { didSet { defaults.set(lastBackupExport, forKey: "lastBackupExport") } }
    var lastAccountChange: Double { didSet { defaults.set(lastAccountChange, forKey: "lastAccountChange") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }
        requireAuth = bool("requireAuth", true)
        autoLockMinutes = int("autoLockMinutes", 5)
        clipboardClearSeconds = int("clipboardClearSeconds", 30)
        hideAfterCopy = bool("hideAfterCopy", false)
        protectScreen = bool("protectScreen", true)
        hideCodes = bool("hideCodes", false)
        defaultGroupID = defaults.string(forKey: "defaultGroupID") ?? ""
        backupReminder = bool("backupReminder", true)
        listMode = bool("listMode", false)
        lastBackupExport = defaults.double(forKey: "lastBackupExport")
        lastAccountChange = defaults.double(forKey: "lastAccountChange")
    }

    /// True if accounts changed after the last exported backup.
    func needsBackup(hasAccounts: Bool) -> Bool {
        backupReminder && hasAccounts && lastAccountChange > lastBackupExport
    }
}
