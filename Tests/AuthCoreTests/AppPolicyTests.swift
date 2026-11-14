import Foundation
import Testing
@testable import AuthCore

@Suite struct AppPolicyTests {
    @Test func lockEpochDropsOldResults() {
        var epoch = LockEpoch()
        let token = epoch.generation
        #expect(epoch.isCurrent(token))
        epoch.bump()
        #expect(!epoch.isCurrent(token))
    }

    @Test func importIntentIsFixedAtCreation() {
        #expect(AppPolicy.canCommit(.addToUnlocked(generation: 3), phase: .unlocked, generation: 3, replaceConfirmed: false))
        #expect(!AppPolicy.canCommit(.addToUnlocked(generation: 3), phase: .unlocked, generation: 4, replaceConfirmed: false))
        #expect(!AppPolicy.canCommit(.addToUnlocked(generation: 3), phase: .locked, generation: 3, replaceConfirmed: true))
        #expect(!AppPolicy.canCommit(.createVault, phase: .locked, generation: 0, replaceConfirmed: true))
        #expect(AppPolicy.canCommit(.createVault, phase: .firstRun, generation: 0, replaceConfirmed: false))
        #expect(!AppPolicy.canCommit(.replaceVault, phase: .locked, generation: 0, replaceConfirmed: false))
        #expect(AppPolicy.canCommit(.replaceVault, phase: .locked, generation: 0, replaceConfirmed: true))
        #expect(!AppPolicy.canCommit(.replaceVault, phase: .unlocked, generation: 0, replaceConfirmed: true))
    }

    @Test func onlyLoweringProtectionNeedsAuthentication() {
        #expect(AppPolicy.requiresFreshAuthentication(.requireAuthentication(from: true, to: false)))
        #expect(!AppPolicy.requiresFreshAuthentication(.requireAuthentication(from: false, to: true)))
        #expect(AppPolicy.requiresFreshAuthentication(.protectScreen(from: true, to: false)))
        #expect(!AppPolicy.requiresFreshAuthentication(.protectScreen(from: false, to: true)))
        #expect(AppPolicy.requiresFreshAuthentication(.hideCodes(from: true, to: false)))
        #expect(!AppPolicy.requiresFreshAuthentication(.hideCodes(from: false, to: true)))
        #expect(AppPolicy.requiresFreshAuthentication(.autoLockMinutes(from: 5, to: 15)))
        #expect(AppPolicy.requiresFreshAuthentication(.autoLockMinutes(from: 60, to: 0)))
        #expect(!AppPolicy.requiresFreshAuthentication(.autoLockMinutes(from: 15, to: 5)))
        #expect(!AppPolicy.requiresFreshAuthentication(.autoLockMinutes(from: 0, to: 60)))
        #expect(!AppPolicy.requiresFreshAuthentication(.autoLockMinutes(from: 5, to: 5)))
    }

    @Test func backupReminderNeedsTheWholeCurrentVault() {
        let a = Account(issuer: "A", name: "a", secret: Data([1, 2, 3]))
        let b = Account(issuer: "B", name: "b", secret: Data([4, 5, 6]))
        let full = VaultData(accounts: [a, b], groups: [])
        #expect(AppPolicy.backupCoversCurrent(exported: full, current: full))
        #expect(!AppPolicy.backupCoversCurrent(exported: VaultData(accounts: [a], groups: []), current: full))
        #expect(!AppPolicy.backupCoversCurrent(exported: VaultData(accounts: [], groups: []), current: VaultData(accounts: [], groups: [])))
    }

    @Test func unlockPromptNeverRightAfterLocking() {
        var policy = UnlockPromptPolicy()
        #expect(policy.autoAllowed)          // app start
        policy.didLock()
        #expect(!policy.autoAllowed)         // same moment as locking
        policy.appResignedWhileLocked()
        #expect(policy.autoAllowed)          // came back after being in the background
        policy.didPrompt()
        #expect(!policy.autoAllowed)
    }
}
