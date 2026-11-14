import CryptoKit
import Foundation
import Testing
@testable import AuthCore

/// Scenarios from the second review round (K1, K2, K4, H3).
struct VaultSafetyTests {
    func makeStore() throws -> (VaultStore, URL) {
        let dir = try tempDirectory()
        let url = dir.appendingPathComponent("Support/vault.json")
        return (VaultStore(url: url), url)
    }

    func testKeychain() -> KeychainProtector {
        KeychainProtector(service: "com.fbrogno.macauth.tests.\(UUID().uuidString)", account: "vault-key")
    }

    func cleanup(_ p: KeychainProtector) {
        for id in (try? p.ownedItemIDs()) ?? [] { try? p.destroyItem(id: id) }
    }

    // K1: a failing changeProtector (read-only folder) must leave the old key usable, also for keychain -> keychain.
    @Test func failedChangeProtectorKeepsOldKeychainKey() async throws {
        let (store, url) = try makeStore()
        let keychain = testKeychain()
        defer { cleanup(keychain) }
        let data = sampleVault()
        try await store.create(contents: data, protector: keychain)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        let before = try Data(contentsOf: url)
        await #expect(throws: VaultError.self) { try await store.changeProtector(to: keychain) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        #expect(try Data(contentsOf: url) == before)                 // file untouched
        #expect(try keychain.ownedItemIDs().count == 1)               // only the new item was removed again
        await store.lock()
        let reopened = VaultStore(url: url)
        try await reopened.load()
        #expect(try await reopened.unlock(using: keychain) == data)   // old key still works
    }

    // H3: the vault key is renewed, old material goes only after the new file is written, previous generation is removed.
    @Test func changeProtectorRenewsKeyAndRemovesOldMaterial() async throws {
        let (store, url) = try makeStore()
        let keychain = testKeychain()
        defer { cleanup(keychain) }
        var data = sampleVault()
        try await store.create(contents: data, protector: keychain)
        let oldFile = try Data(contentsOf: url)
        let oldItem = try keychain.ownedItemIDs()
        data.accounts.removeLast()
        try await store.save(data)
        #expect(await store.hasPreviousGeneration)

        try await store.changeProtector(to: keychain)
        #expect(!(await store.hasPreviousGeneration))                 // still on the old key, removed
        let ids = try keychain.ownedItemIDs()
        #expect(ids.count == 1 && ids != oldItem)                     // old item destroyed, new one exists
        #expect(try Data(contentsOf: url) != oldFile)
        await store.lock()
        let reopened = VaultStore(url: url)
        try await reopened.load()
        #expect(try await reopened.unlock(using: keychain) == data)
    }

    @Test func orphanCleanupRemovesOnlyUnreferencedItems() async throws {
        let (store, url) = try makeStore()
        let keychain = testKeychain()
        defer { cleanup(keychain) }
        try await store.create(contents: sampleVault(), protector: keychain)
        let live = try keychain.ownedItemIDs()
        let orphan = try keychain.wrap(vaultKey: SymmetricKey(size: .bits256))["item"]!

        // Referenced only by a set-aside file (even one with an unknown version): kept.
        let kept = try keychain.wrap(vaultKey: SymmetricKey(size: .bits256))["item"]!
        let aside = url.deletingLastPathComponent().appendingPathComponent("vault.replaced-20260101T000000Z.json")
        try Data("{\"version\":9,\"protector\":\"keychain\",\"protectorFields\":{\"item\":\"\(kept)\"}}".utf8).write(to: aside)

        #expect(try await store.removeOrphanedKeyMaterial() == 1)
        let remaining = Set(try keychain.ownedItemIDs())
        #expect(remaining == Set(live + [kept]))
        #expect(!remaining.contains(orphan))

        // Locked: not callable.
        await store.lock()
        await #expect(throws: VaultError.locked) { try await store.removeOrphanedKeyMaterial() }
    }

    @Test func orphanCleanupRefusesWhenCurrentFileIsUnreadable() async throws {
        let (store, url) = try makeStore()
        let keychain = testKeychain()
        defer { cleanup(keychain) }
        try await store.create(contents: sampleVault(), protector: keychain)
        _ = try keychain.wrap(vaultKey: SymmetricKey(size: .bits256))
        let count = try keychain.ownedItemIDs().count
        try Data("garbage".utf8).write(to: url)
        await #expect(throws: VaultError.corrupted) { try await store.removeOrphanedKeyMaterial() }
        #expect(try keychain.ownedItemIDs().count == count)
        // An unreadable previous/replaced candidate also stops it.
        let (store2, url2) = try makeStore()
        let k2 = testKeychain()
        defer { cleanup(k2) }
        try await store2.create(contents: sampleVault(), protector: k2)
        _ = try k2.wrap(vaultKey: SymmetricKey(size: .bits256))
        let aside = url2.deletingLastPathComponent().appendingPathComponent("vault.replaced-20260101T000000Z.json")
        try Data("x".utf8).write(to: aside)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: aside.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aside.path) }
        let n = try k2.ownedItemIDs().count
        await #expect(throws: VaultError.unreadableKeyFiles) { try await store2.removeOrphanedKeyMaterial() }
        #expect(try k2.ownedItemIDs().count == n)
    }

    // K2: replacing a version-2 file keeps it byte for byte.
    @Test func replacingKeepsOldFileUnchanged() async throws {
        let (store, url) = try makeStore()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreign = Data("{\"version\":2,\"protector\":\"secure-enclave\",\"future\":[1,2,3]}".utf8)
        try foreign.write(to: url)
        let previous = Data("old previous".utf8)
        try previous.write(to: store.previousURL)
        await #expect(throws: VaultError.unsupportedVersion(2)) { try await store.load() }
        await #expect(throws: VaultError.alreadyExists) { try await store.create(protector: InMemoryProtector()) }
        #expect(try Data(contentsOf: url) == foreign)

        let protector = InMemoryProtector()
        let data = sampleVault()
        try await store.create(contents: data, protector: protector, replacingExisting: true)
        let files = await store.replacedFiles()
        #expect(files.count == 2)
        let contents = try files.map { try Data(contentsOf: $0.url) }
        #expect(contents.contains(foreign) && contents.contains(previous))
        #expect(files.contains { $0.protectorIdentifier == "secure-enclave" })
        #expect(try await store.load() == .locked)
        #expect(try await store.unlock(using: protector) == data)

        // Restoring it sets the current vault aside in turn.
        let current = try Data(contentsOf: url)
        let target = files.first { $0.protectorIdentifier == "secure-enclave" }!
        await #expect(throws: VaultError.unsupportedVersion(2)) { try await store.restoreReplaced(target) }
        #expect(try Data(contentsOf: url) == foreign)
        let after = await store.replacedFiles()
        #expect(try after.map { try Data(contentsOf: $0.url) }.contains(current))
        #expect(!after.contains { $0.url == target.url })
    }

    @Test func replacedFilesAreNeverDeletedAndOrderedNewestFirst() async throws {
        let (store, url) = try makeStore()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for stamp in ["20260101T000000Z", "20260301T120000Z"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent("vault.replaced-\(stamp).json"))
        }
        let files = await store.replacedFiles()
        #expect(files.map(\.url.lastPathComponent) == ["vault.replaced-20260301T120000Z.json", "vault.replaced-20260101T000000Z.json"])
        #expect(files[0].date > files[1].date)
        #expect(files[0].date == Date(timeIntervalSince1970: 1_772_366_400))
        try await store.create(protector: InMemoryProtector())
        try await store.destroy()
        #expect(await store.replacedFiles().count == 2)
        await #expect(throws: VaultError.replacedFileNotFound) {
            try await store.restoreReplaced(ReplacedVaultFile(url: dir.appendingPathComponent("evil.json"), date: Date(), protectorIdentifier: nil))
        }
    }

    @Test func foreignFileAtSaveTimeIsSetAside() async throws {
        let (store, url) = try makeStore()
        let protector = InMemoryProtector()
        let data = sampleVault()
        try await store.create(contents: data, protector: protector)
        let foreign = Data("someone else wrote this".utf8)
        try foreign.write(to: url)
        try await store.save(data)
        let files = await store.replacedFiles()
        #expect(files.count == 1)
        #expect(try Data(contentsOf: files[0].url) == foreign)
    }

    @Test func hasPreviousGenerationIsLive() async throws {
        let (store, _) = try makeStore()
        try await store.create(contents: sampleVault(), protector: InMemoryProtector())
        try await store.save(sampleVault())
        #expect(await store.hasPreviousGeneration)
        try FileManager.default.removeItem(at: store.previousURL)
        #expect(!(await store.hasPreviousGeneration))
    }

    // K4: a refusing protector gets no contents out, also while unlocked.
    struct Refusing: KeyProtector {
        let identifier = "memory"
        func wrap(vaultKey: SymmetricKey) throws -> ProtectorFields { [:] }
        func unwrap(fields: ProtectorFields) throws -> SymmetricKey { throw ProtectorError.userCancelled }
    }

    @Test func refusingProtectorNeverReturnsContentsWhileUnlocked() async throws {
        let (store, _) = try makeStore()
        let protector = InMemoryProtector()
        let data = sampleVault()
        try await store.create(contents: data, protector: protector)
        #expect(await store.state == .unlocked)
        await #expect(throws: ProtectorError.userCancelled) { try await store.unlock(using: Refusing()) }
        #expect(try await store.unlock(using: protector) == data)    // asks the real protector, then returns
    }

    final class SlowProtector: KeyProtector, @unchecked Sendable {
        let identifier = "memory"
        let inner: InMemoryProtector
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        init(inner: InMemoryProtector) { self.inner = inner }
        func wrap(vaultKey: SymmetricKey) throws -> ProtectorFields { try inner.wrap(vaultKey: vaultKey) }
        func unwrap(fields: ProtectorFields) throws -> SymmetricKey {
            started.signal()
            release.wait()
            return try inner.unwrap(fields: fields)
        }
    }

    @Test func lockDuringPendingUnlockDiscardsTheResult() async throws {
        let (store, _) = try makeStore()
        let inner = InMemoryProtector()
        try await store.create(contents: sampleVault(), protector: inner)
        await store.lock()
        let generation = await store.lockGeneration
        let slow = SlowProtector(inner: inner)
        let pending = Task { try await store.unlock(using: slow) }
        await withCheckedContinuation { c in DispatchQueue.global().async { slow.started.wait(); c.resume() } }
        await store.lock()                                            // while the "Touch ID prompt" is open
        #expect(await store.lockGeneration == generation + 1)
        slow.release.signal()
        await #expect(throws: VaultError.locked) { try await pending.value }
        #expect(await store.state == .locked)
        #expect(await store.contents == nil)
    }

    @Test func lockGenerationIncreasesOnEveryLock() async throws {
        let (store, _) = try makeStore()
        try await store.create(protector: InMemoryProtector())
        let g = await store.lockGeneration
        await store.lock()
        await store.lock()
        #expect(await store.lockGeneration == g + 2)
    }

    @Test func atomicWriteLeavesNoTempFilesAndSetsMode() throws {
        let dir = try tempDirectory()
        let file = dir.appendingPathComponent("a.json")
        try AtomicFile.write(Data("one".utf8), to: file)
        try AtomicFile.write(Data("two".utf8), to: file)
        #expect(try Data(contentsOf: file) == Data("two".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["a.json"])
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
    }
}
