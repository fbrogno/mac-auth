import Foundation

/// Rules of the app layer that are pure logic and therefore tested here (the app target has no test target).

public enum AppPhase: Equatable, Sendable {
    case loading, firstRun, locked, unlocked
}

/// What an import session is allowed to do. Fixed when the session is created, never derived from the
/// phase at the moment the user confirms.
public enum ImportIntent: Equatable, Sendable {
    /// Add to the unlocked vault; valid only in the lock generation it was created in.
    case addToUnlocked(generation: Int)
    /// First start: create the vault.
    case createVault
    /// Rescue: replace a vault that cannot be opened (the old file is kept by the core). Needs an explicit confirmation.
    case replaceVault
}

public enum SecuritySettingChange: Equatable, Sendable {
    case requireAuthentication(from: Bool, to: Bool)
    /// Minutes; 0 = never.
    case autoLockMinutes(from: Int, to: Int)
    case protectScreen(from: Bool, to: Bool)
    case hideCodes(from: Bool, to: Bool)
}

public enum AppPolicy {
    public static func canCommit(_ intent: ImportIntent, phase: AppPhase, generation: Int, replaceConfirmed: Bool) -> Bool {
        switch intent {
        case .addToUnlocked(let created): return phase == .unlocked && created == generation
        case .createVault: return phase == .firstRun
        case .replaceVault: return phase == .locked && replaceConfirmed
        }
    }

    /// Every step that lowers protection needs a fresh Touch ID / password check; raising it does not.
    public static func requiresFreshAuthentication(_ change: SecuritySettingChange) -> Bool {
        switch change {
        case .requireAuthentication(let from, let to): return from && !to
        case .protectScreen(let from, let to): return from && !to
        case .hideCodes(let from, let to): return from && !to
        case .autoLockMinutes(let from, let to):
            func rank(_ m: Int) -> Int { m <= 0 ? Int.max : m }
            return rank(to) > rank(from)
        }
    }

    /// The backup reminder may only be reset by a backup of the complete current vault.
    public static func backupCoversCurrent(exported: VaultData, current: VaultData) -> Bool {
        !exported.accounts.isEmpty && exported == current
    }
}

/// Counts locks; a result that was started in an older generation must be dropped.
public struct LockEpoch: Equatable, Sendable {
    public private(set) var generation = 0
    public init() {}
    public mutating func bump() { generation += 1 }
    public func isCurrent(_ token: Int) -> Bool { token == generation }
}

/// When the unlock prompt may appear by itself: at app start, and when the app comes back to the front after it
/// was in the background while locked. Never right after locking, never before the user acted.
public struct UnlockPromptPolicy: Equatable, Sendable {
    public private(set) var autoAllowed = true
    public init() {}
    public mutating func didLock() { autoAllowed = false }
    public mutating func appResignedWhileLocked() { autoAllowed = true }
    /// The user pressed "Unlock" or brought the app forward on purpose: consumed by one prompt.
    public mutating func didPrompt() { autoAllowed = false }
}
