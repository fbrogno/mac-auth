import CryptoKit
import Foundation
import Testing
@testable import AuthCore

/// Round 4: key availability, authenticated app-lock flag, key material still needed by set-aside files, orphan clean-up.
struct Round4Tests {
    func makeStore() throws -> (VaultStore, URL) {
        let dir = try tempDirectory()
        let url = dir.appendingPathComponent("Support/vault.json")
        return (VaultStore(url: url), url)
    }

    func testKeychain(account: String = "vault-key") -> KeychainProtector {
        KeychainProtector(service: "com.fbrogno.macauth.tests.\(UUID().uuidString)", account: account)
    }

    func cleanup(_ p: KeychainProtector) {
        for id in (try? p.ownedItemIDs()) ?? [] { try? p.destroyItem(id: id) }
    }

    // MARK: N-H1 key availability

    /// A blob the enclave does not know (another Mac, a reset) must be reported as `keyUnavailable`, never as
    /// "retry later". Skipped where the enclave cannot be used unattended; the mapping itself is tested always
    /// (`ProtectorTests.errorClassification`).
    @Test(.enabled(if: enclaveUsable))
    func foreignEnclaveBlobIsKeyUnavailableOrCorrupt() throws {
        let p = SecureEnclaveProtector(accessControlFlags: [.privateKeyUsage])
        var fields = try p.wrap(vaultKey: SymmetricKey(size: .bits256))
        var blob = Data(base64Encoded: fields["keyBlob"]!)!
        for i in 0..<min(blob.count, 24) { blob[i] ^= 0xA5 }
        fields["keyBlob"] = blob.base64EncodedString()
        do {
            _ = try p.unwrap(fields: fields)
            Issue.record("a damaged blob must not unwrap")
        } catch let error as ProtectorError {
            switch error {
            case .keyUnavailable, .secureEnclaveFailure, .dataCorrupted: break
            case .interactionNotAllowed: Issue.record("unknown blob wrongly classified as temporary")
            default: Issue.record("unexpected \(error)")
            }
        }
    }

    // MARK: N-H2 authenticated app-lock flag

    @Test func appLockFlagRoundTripsAndIsPartOfTheHeader() async throws {
        let (store, url) = try makeStore()
        let p = InMemoryProtector()
        let data = sampleVault()
        try await store.create(contents: data, protector: p, requireAppAuthentication: false)
        #expect(await store.requiresAppAuthentication == false)
        try await store.setRequiresAppAuthentication(true)
        #expect(await store.requiresAppAuthentication == true)
        try await store.setRequiresAppAuthentication(false)
        await store.lock()
        let reopened = VaultStore(url: url)
        try await reopened.load()
        #expect(await reopened.requiresAppAuthentication == false)       // readable before unlocking
        #expect(try await reopened.unlock(using: p) == data)
        // Locked: not changeable.
        await reopened.lock()
        await #expect(throws: VaultError.locked) { try await reopened.setRequiresAppAuthentication(true) }
    }

    @Test func manipulatedAppLockFlagIsRejected() async throws {
        for flagAtCreate in [false, true] {
            let (store, url) = try makeStore()
            let p = InMemoryProtector()
            let data0 = sampleVault()
            try await store.create(contents: data0, protector: p, requireAppAuthentication: flagAtCreate)
            await store.lock()
            let original = try Data(contentsOf: url)
            func tampered(_ change: (inout [String: Any]) -> Void) throws -> Data {
                var json = try JSONSerialization.jsonObject(with: original) as! [String: Any]
                change(&json)
                return try JSONSerialization.data(withJSONObject: json)
            }
            for data in [try tampered { $0["appLock"] = !flagAtCreate },     // flipped
                         try tampered { $0.removeValue(forKey: "appLock") }] { // removed
                try data.write(to: url)
                let s = VaultStore(url: url)
                try await s.load()
                await #expect(throws: VaultError.corrupted) { try await s.unlock(using: p) }
            }
            try original.write(to: url)
            let s = VaultStore(url: url)
            try await s.load()
            #expect(try await s.unlock(using: p) == data0)           // untouched file still opens
        }
    }

    @Test func fileWithoutAppLockFieldCountsAsRequiredAndStillOpens() async throws {
        let (store, url) = try makeStore()
        let p = InMemoryProtector()
        let key = SymmetricKey(size: .bits256)
        let fields = try p.wrap(vaultKey: key)
        let data = sampleVault()
        let legacy = try VaultStore.seal(data, key: key, protector: p.identifier, fields: fields, appLock: nil)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        try encoder.encode(legacy).write(to: url)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("appLock") == false)
        try await store.load()
        #expect(await store.requiresAppAuthentication == true)
        #expect(try await store.unlock(using: p) == data)
        // Adding the field to such a file without the key breaks it.
        await store.lock()
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["appLock"] = false
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let s = VaultStore(url: url)
        try await s.load()
        await #expect(throws: VaultError.corrupted) { try await s.unlock(using: p) }
    }

    @Test func saveAndProtectorChangeKeepTheFlag() async throws {
        let (store, _) = try makeStore()
        let keychain = testKeychain()
        defer { cleanup(keychain) }
        try await store.create(contents: sampleVault(), protector: InMemoryProtector(), requireAppAuthentication: false)
        try await store.save(VaultData(accounts: [makeAccount()], groups: []))
        #expect(await store.requiresAppAuthentication == false)
        try await store.changeProtector(to: keychain)
        #expect(await store.requiresAppAuthentication == false)
        try await store.changeProtector(to: InMemoryProtector(), requireAppAuthentication: true)
        #expect(await store.requiresAppAuthentication == true)
    }

    // MARK: N-M1 changeProtector keeps keys that set-aside files still need

    @Test func changeProtectorKeepsKeyNeededBySetAsideFile() async throws {
        let (store, url) = try makeStore()
        let keychain = testKeychain()
        defer { cleanup(keychain) }
        var data = sampleVault()
        try await store.create(contents: data, protector: keychain)
        data.accounts.removeLast()
        try await store.save(data)                                   // previous generation exists (same key)
        // Newer file unreadable -> previous generation recovered; the broken file is set aside as vault.replaced-*.
        await store.lock()
        let good = try Data(contentsOf: url)
        var json = try JSONSerialization.jsonObject(with: good) as! [String: Any]
        json["ciphertext"] = flipByte(inBase64: json["ciphertext"] as! String)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        try await store.load()
        try await store.recoverPreviousGeneration()
        #expect(await store.replacedFiles().count == 1)
        _ = try await store.unlock(using: keychain)
        let oldItems = try keychain.ownedItemIDs()
        #expect(oldItems.count == 1)

        try await store.changeProtector(to: keychain)                // new key; old item is referenced by replaced-*
        let items = try keychain.ownedItemIDs()
        #expect(items.count == 2)                                    // old item kept, new one added
        #expect(oldItems.allSatisfy(items.contains))
        // The set-aside file can still be brought back and opened.
        await store.lock()
        let aside = try #require(await store.replacedFiles().first)
        try await store.restoreReplaced(aside)
        // (its ciphertext was damaged on purpose; the point is that the KEY is still there)
        let fields = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any])["protectorFields"] as! [String: String]
        _ = try keychain.unwrap(fields: fields)

        // Without any set-aside file the old key is removed as before.
        let (store2, _) = try makeStore()
        let k2 = testKeychain()
        defer { cleanup(k2) }
        try await store2.create(contents: sampleVault(), protector: k2)
        try await store2.changeProtector(to: k2)
        #expect(try k2.ownedItemIDs().count == 1)
    }

    // MARK: N-N4 orphan clean-up across services, legacy items

    @Test func orphanCleanupAlsoChecksKeychainWhileVaultUsesAnotherProtector() async throws {
        let (store, _) = try makeStore()
        let keychain = testKeychain()
        defer { cleanup(keychain) }
        let current = InMemoryProtector()                            // stands for the Secure Enclave
        try await store.create(contents: sampleVault(), protector: current)
        let orphan = try keychain.wrap(vaultKey: SymmetricKey(size: .bits256))["item"]!
        #expect(try await store.removeOrphanedKeyMaterial() == 0)    // not asked about the keychain: untouched
        #expect(try keychain.ownedItemIDs() == [orphan])
        #expect(try await store.removeOrphanedKeyMaterial(alsoCheck: [keychain]) == 1)
        #expect(try keychain.ownedItemIDs().isEmpty)
    }

    @Test func legacyItemIsKeptWhileAnyLegacyFileExists() async throws {
        let (store, url) = try makeStore()
        let service = "com.fbrogno.macauth.tests.\(UUID().uuidString)"
        let keychain = KeychainProtector(service: service, account: "vault-key")
        defer { cleanup(keychain) }
        // A legacy item (plain account name, no `item` field) and a legacy-format set-aside file that needs it.
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "vault-key", kSecAttrSynchronizable as String: false]
        q[kSecValueData as String] = Data(repeating: 7, count: 32)
        #expect(SecItemAdd(q as CFDictionary, nil) == errSecSuccess)
        try await store.create(contents: sampleVault(), protector: keychain)    // new-style item "vault-key-<UUID>"
        let aside = url.deletingLastPathComponent().appendingPathComponent("vault.replaced-20260101T000000Z.json")
        try Data("{\"version\":1,\"protector\":\"keychain\",\"protectorFields\":{}}".utf8).write(to: aside)

        #expect(try await store.removeOrphanedKeyMaterial() == 0)
        #expect(try keychain.ownedItemIDs().contains("vault-key"))               // legacy item survives

        try FileManager.default.removeItem(at: aside)                            // no legacy file left
        #expect(try await store.removeOrphanedKeyMaterial() == 1)
        #expect(try !keychain.ownedItemIDs().contains("vault-key"))
        #expect(try keychain.ownedItemIDs().count == 1)                          // the live item stays
    }
}
