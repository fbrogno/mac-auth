import Foundation
import LocalAuthentication

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
    /// Seconds; 0 = never.
    case clipboardClearSeconds(from: Int, to: Int)
}

/// Result of a Touch ID / login password check. Only the user's own cancel is "cancelled"; every other failure is
/// "failed" and must still lead to the screen that offers the recovery options.
public enum AuthOutcome: Equatable, Sendable {
    case success
    /// This Mac has no login password: the check cannot ask anything and passes. Nothing protects the action.
    case noPasscode
    case cancelled
    case failed

    public var isGranted: Bool { self == .success || self == .noPasscode }

    public static func from(_ code: LAError.Code) -> AuthOutcome {
        switch code {
        case .passcodeNotSet: .noPasscode
        case .userCancel, .systemCancel, .appCancel: .cancelled
        default: .failed
        }
    }
}

/// Proof that the user authenticated for a recovery from the lock screen (restore an earlier version, a set-aside
/// file, the previous generation, or a backup file). Valid for one lock generation and a few minutes, and used up
/// by the restore it was given for.
public struct RecoveryAuthorization: Equatable, Sendable {
    public static let validity: TimeInterval = 300
    private var generation: Int?
    private var grantedAt: Date?

    public init() {}

    public mutating func grant(generation: Int, now: Date = Date()) {
        self.generation = generation
        grantedAt = now
    }

    public func permits(generation: Int, now: Date = Date()) -> Bool {
        guard let granted = self.generation, let grantedAt else { return false }
        let age = now.timeIntervalSince(grantedAt)
        return granted == generation && age >= 0 && age <= Self.validity
    }

    public mutating func consume() {
        generation = nil
        grantedAt = nil
    }
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
        case .clipboardClearSeconds(let from, let to):
            func rank(_ s: Int) -> Int { s <= 0 ? Int.max : s }
            return rank(to) > rank(from)
        case .autoLockMinutes(let from, let to):
            func rank(_ m: Int) -> Int { m <= 0 ? Int.max : m }
            return rank(to) > rank(from)
        }
    }

    /// The backup reminder may only be reset by a backup of the complete current vault.
    public static func backupCoversCurrent(exported: VaultData, current: VaultData) -> Bool {
        // Security settings and the usage history (`lastUsedAt`) are not part of a backup, so they are not compared.
        let (exported, current) = (exported.withoutUsage, current.withoutUsage)
        return !exported.accounts.isEmpty && exported.accounts == current.accounts && exported.groups == current.groups
    }

    /// What has to be written when the vault locks or the app quits. A real change is saved as usual (rotating the
    /// previous generation); a bare usage note (`lastUsedAt` after copying) is written without rotating it.
    public enum ExitWrite: Equatable, Sendable { case nothing, full, usageOnly }

    public static func exitWrite(unsavedChange: Bool, unsavedUsage: Bool) -> ExitWrite {
        if unsavedChange { return .full }
        return unsavedUsage ? .usageOnly : .nothing
    }

    /// The version shown in the update notice comes from the (unsigned) appcast: only a short, harmless string is
    /// displayed. Returns nil if nothing usable is left, so the caller shows a text without a version.
    public static func displayVersion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.-+ ")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 20, trimmed.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
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
