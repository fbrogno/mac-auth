import Foundation

/// The four settings that decide how much the app protects the codes on screen and in the clipboard. They live
/// inside the encrypted, authenticated vault payload, so a change to the (unauthenticated) preferences file cannot
/// lower them. A missing value means the strict default. Not part of backup files and never merged from imports.
public struct SecuritySettings: Codable, Sendable, Equatable {
    public static let allowedAutoLockMinutes = [0, 1, 5, 15, 60]
    public static let allowedClipboardSeconds = [0, 10, 30, 60]

    /// Minutes of inactivity before locking; 0 = never.
    public var autoLockMinutes: Int
    public var protectScreen: Bool
    public var hideCodes: Bool
    /// Seconds until the clipboard is cleared; 0 = never.
    public var clipboardClearSeconds: Int

    public static let defaultAutoLockMinutes = 5
    public static let defaultClipboardSeconds = 30

    /// What applies while the vault is locked, in a vault that never stored settings and in a restored vault.
    public static let strict = SecuritySettings()

    public init(autoLockMinutes: Int = SecuritySettings.defaultAutoLockMinutes, protectScreen: Bool = true,
                hideCodes: Bool = false, clipboardClearSeconds: Int = SecuritySettings.defaultClipboardSeconds) {
        self.autoLockMinutes = Self.allowedAutoLockMinutes.contains(autoLockMinutes) ? autoLockMinutes : Self.defaultAutoLockMinutes
        self.protectScreen = protectScreen
        self.hideCodes = hideCodes
        self.clipboardClearSeconds = Self.allowedClipboardSeconds.contains(clipboardClearSeconds) ? clipboardClearSeconds : Self.defaultClipboardSeconds
    }

    private enum CodingKeys: String, CodingKey { case autoLockMinutes, protectScreen, hideCodes, clipboardClearSeconds }

    /// Missing or unusable fields fall back to the strict default, one by one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(autoLockMinutes: (try? c.decodeIfPresent(Int.self, forKey: .autoLockMinutes)) ?? Self.defaultAutoLockMinutes,
                  protectScreen: (try? c.decodeIfPresent(Bool.self, forKey: .protectScreen)) ?? true,
                  hideCodes: (try? c.decodeIfPresent(Bool.self, forKey: .hideCodes)) ?? false,
                  clipboardClearSeconds: (try? c.decodeIfPresent(Int.self, forKey: .clipboardClearSeconds)) ?? Self.defaultClipboardSeconds)
    }

    /// Values of the old, unauthenticated preferences file (1.0.0). Only the values that were actually stored.
    public struct Legacy: Equatable, Sendable {
        public var autoLockMinutes: Int?
        public var protectScreen: Bool?
        public var hideCodes: Bool?
        public var clipboardClearSeconds: Int?

        public init(autoLockMinutes: Int? = nil, protectScreen: Bool? = nil, hideCodes: Bool? = nil, clipboardClearSeconds: Int? = nil) {
            self.autoLockMinutes = autoLockMinutes
            self.protectScreen = protectScreen
            self.hideCodes = hideCodes
            self.clipboardClearSeconds = clipboardClearSeconds
        }

        public var isEmpty: Bool { self == Legacy() }
    }

    /// One-time migration: an old value is adopted only if it is at least as strict as the default; otherwise the
    /// default is used (the old file could have been edited without authentication).
    public static func migrated(from legacy: Legacy) -> SecuritySettings {
        var result = SecuritySettings.strict
        func rank(_ minutes: Int) -> Int { minutes <= 0 ? Int.max : minutes }
        if let m = legacy.autoLockMinutes, allowedAutoLockMinutes.contains(m), rank(m) <= rank(defaultAutoLockMinutes) {
            result.autoLockMinutes = m
        }
        if let s = legacy.clipboardClearSeconds, allowedClipboardSeconds.contains(s), rank(s) <= rank(defaultClipboardSeconds) {
            result.clipboardClearSeconds = s
        }
        if let p = legacy.protectScreen, p { result.protectScreen = true }   // default is on: only "on" is adopted
        if let h = legacy.hideCodes { result.hideCodes = h }                  // default is off: either value is at least as strict
        return result
    }
}

extension VaultData {
    /// The settings to use after unlocking: the vault's own, or nil if the vault has none yet and the old
    /// preferences should be migrated (the caller stores the result, then removes the old keys).
    public static func settingsToMigrate(vault: SecuritySettings?, legacy: SecuritySettings.Legacy) -> SecuritySettings? {
        guard vault == nil, !legacy.isEmpty else { return nil }
        return SecuritySettings.migrated(from: legacy)
    }
}
