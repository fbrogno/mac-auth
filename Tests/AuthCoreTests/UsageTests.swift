import Foundation
import Testing
@testable import AuthCore

/// `lastUsedAt` (the quick access order) is a note about use, not a change of the vault.
@Suite struct UsageTests {
    private func makeStore() throws -> (VaultStore, URL) {
        let url = try tempDirectory().appendingPathComponent("vault.json")
        return (VaultStore(url: url), url)
    }

    private func used(_ vault: VaultData, at seconds: TimeInterval = 1_800_000_000) -> VaultData {
        var copy = vault
        copy.accounts[0].lastUsedAt = Date(timeIntervalSince1970: seconds)
        return copy
    }

    // MARK: Store

    @Test func usageOnlySaveKeepsThePreviousGenerationUntouched() async throws {
        let (store, url) = try makeStore()
        let protector = InMemoryProtector()
        var data = sampleVault()
        try await store.create(contents: data, protector: protector)
        data.accounts.append(makeAccount("second", secret: "second-secret-0123456789"))
        try await store.save(data)   // a real change: the first generation becomes the previous one
        let previousBefore = try Data(contentsOf: store.previousURL)
        let currentBefore = try Data(contentsOf: url)

        let noted = used(data)
        try await store.saveUsage(noted)

        #expect(try Data(contentsOf: store.previousURL) == previousBefore)   // still the state before the last real change
        #expect(try Data(contentsOf: url) != currentBefore)                   // the note is written
        #expect(await store.contents == noted)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted()
        #expect(names == ["vault.json", "vault.previous.json"])   // nothing set aside, nothing left over

        // The note survives a lock and unlock.
        await store.lock()
        let reopened = VaultStore(url: url)
        try await reopened.load()
        #expect(try await reopened.unlock(using: protector) == noted)
    }

    @Test func usageOnlySaveCreatesNoPreviousGeneration() async throws {
        let (store, _) = try makeStore()
        let data = sampleVault()
        try await store.create(contents: data, protector: InMemoryProtector())
        try await store.saveUsage(used(data))
        #expect(!(await store.hasPreviousGeneration))
    }

    @Test func aRealChangeAfterAUsageNoteRotatesAgain() async throws {
        // HOTP advance, edit and so on use `save`: the previous generation moves, and carries the earlier note.
        let (store, url) = try makeStore()
        var data = sampleVault()
        try await store.create(contents: data, protector: InMemoryProtector())
        data = used(data)
        try await store.saveUsage(data)
        let currentBeforeAdvance = try Data(contentsOf: url)
        data.accounts[1].advanceCounter()
        try await store.save(data)
        #expect(try Data(contentsOf: store.previousURL) == currentBeforeAdvance)
        #expect(await store.contents?.accounts[1].counter == 8)
    }

    @Test func usageSaveNeedsAnUnlockedVault() async throws {
        let (store, _) = try makeStore()
        try await store.create(contents: sampleVault(), protector: InMemoryProtector())
        await store.lock()
        await #expect(throws: VaultError.locked) { try await store.saveUsage(sampleVault()) }
    }

    // MARK: Backup and exports

    @Test func backupRoundTripCarriesNoUsage() throws {
        let base = sampleVault()
        let data = used(base)
        let file = try BackupFile.encrypt(data, password: "correct horse battery", iterations: 1000)
        let restored = try BackupFile.decrypt(file, password: "correct horse battery", acceptedIterations: 1000...10_000_000)
        #expect(restored.accounts.allSatisfy { $0.lastUsedAt == nil })
        #expect(restored == base)
        // A file that carries it anyway (older or foreign): it is dropped on reading.
        let raw = try VaultData.makeEncoder().encode(data)
        let crafted = try BackupFile.encryptRaw(raw, password: "correct horse battery", iterations: 1000)
        let read = try BackupFile.decrypt(crafted, password: "correct horse battery", acceptedIterations: 1000...10_000_000)
        #expect(read.accounts.allSatisfy { $0.lastUsedAt == nil })
    }

    @Test func plainExportsCarryNoUsage() throws {
        let plain = sampleVault(), noted = used(plain)
        let list = AccountExporter.otpauthList(noted.accounts).data
        #expect(list == AccountExporter.otpauthList(plain.accounts).data)
        let aegis = String(decoding: try AccountExporter.aegisJSON(noted.accounts, groups: noted.groups).data, as: UTF8.self)
        for text in [String(decoding: list, as: UTF8.self), aegis] {
            #expect(!text.contains("1800000000") && !text.contains("lastUsed") && !text.contains("2027"))
        }
    }

    @Test func backupReminderIgnoresUsage() {
        let saved = sampleVault()
        let current = used(saved)
        // A backup made before the copy still covers the vault: using an account is not a change.
        #expect(AppPolicy.backupCoversCurrent(exported: saved, current: current))
        #expect(AppPolicy.backupCoversCurrent(exported: current, current: saved))
        // A real change still does not.
        var changed = saved
        changed.accounts[1].advanceCounter()
        #expect(!AppPolicy.backupCoversCurrent(exported: saved, current: changed))
        var renamed = saved
        renamed.accounts[0].name = "other"
        #expect(!AppPolicy.backupCoversCurrent(exported: saved, current: used(renamed)))
    }

    // MARK: Exit

    @Test func exitWritesTheUsageNoteOnlyWhenNothingElseIsPending() {
        #expect(AppPolicy.exitWrite(unsavedChange: false, unsavedUsage: false) == .nothing)
        #expect(AppPolicy.exitWrite(unsavedChange: false, unsavedUsage: true) == .usageOnly)
        #expect(AppPolicy.exitWrite(unsavedChange: true, unsavedUsage: false) == .full)
        #expect(AppPolicy.exitWrite(unsavedChange: true, unsavedUsage: true) == .full)
    }

    // MARK: Edit sheet (N2)

    @Test func savingTheEditSheetKeepsCounterAndUsage() {
        let sheetCopy = makeAccount("old name", kind: .hotp, counter: 7)   // what the sheet was opened with
        var current = sheetCopy
        current.counter = 9                                                 // advanced while the sheet was open
        current.lastUsedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let group = UUID()
        let merged = current.applying(AccountEdit(issuer: "New", name: "new name", groupID: group, note: "n"))
        #expect(merged.counter == 9)
        #expect(merged.lastUsedAt == current.lastUsedAt)
        #expect(merged.issuer == "New" && merged.name == "new name" && merged.groupID == group && merged.note == "n")
        #expect(merged.secret == current.secret && merged.id == current.id && merged.sortIndex == current.sortIndex && merged.pinned == current.pinned)
    }
}
