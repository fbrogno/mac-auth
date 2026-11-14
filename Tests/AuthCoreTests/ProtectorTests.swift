import CryptoKit
import Foundation
import Security
import Testing
@testable import AuthCore

/// Secure Enclave tests are skipped (not passed, not failed) where the enclave cannot be used without a prompt:
/// no enclave at all, or shells without keychain interaction (-25308).
let enclaveUsable: Bool = {
    guard SecureEnclaveProtector.isAvailable else { return false }
    let p = SecureEnclaveProtector(accessControlFlags: [.privateKeyUsage])
    return (try? p.wrap(vaultKey: SymmetricKey(size: .bits256))) != nil
}()

struct ProtectorTests {
    func keyBytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    @Test func inMemoryWrapUnwrap() throws {
        let p = InMemoryProtector()
        let key = SymmetricKey(size: .bits256)
        let fields = try p.wrap(vaultKey: key)
        #expect(keyBytes(try p.unwrap(fields: fields)) == keyBytes(key))
        #expect(throws: ProtectorError.dataCorrupted) { try InMemoryProtector().unwrap(fields: fields) }
        #expect(throws: ProtectorError.dataCorrupted) { try p.unwrap(fields: [:]) }
        #expect(throws: ProtectorError.dataCorrupted) { try p.unwrap(fields: ["wrapped": "%%%"]) }
    }

    func cleanup(_ p: KeychainProtector) {
        for id in (try? p.ownedItemIDs()) ?? [] { try? p.destroyItem(id: id) }
    }

    @Test func keychainWrapNeverDeletesAndEachItemStandsAlone() throws {
        let service = "com.fbrogno.macauth.tests.\(UUID().uuidString)"
        let p = KeychainProtector(service: service, account: "vault-key")
        defer { cleanup(p) }
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let f1 = try p.wrap(vaultKey: key1)
        let f2 = try p.wrap(vaultKey: key2)           // must not touch the first item
        #expect(f1["item"] != f2["item"])
        #expect(f1["item"]?.hasPrefix("vault-key-") == true)
        #expect(try p.ownedItemIDs().count == 2)
        #expect(keyBytes(try p.unwrap(fields: f1)) == keyBytes(key1))
        #expect(keyBytes(try p.unwrap(fields: f2)) == keyBytes(key2))

        try p.destroy(fields: f1)                      // removes exactly its own item
        #expect(throws: ProtectorError.keyNotFound) { try p.unwrap(fields: f1) }
        #expect(keyBytes(try p.unwrap(fields: f2)) == keyBytes(key2))
        try p.destroy(fields: f1)                      // idempotent
        #expect(try p.ownedItemIDs() == [f2["item"]!])

        // Fields pointing outside this protector's namespace are refused.
        #expect(throws: ProtectorError.dataCorrupted) { try p.unwrap(fields: ["item": "other"]) }
        #expect(throws: ProtectorError.dataCorrupted) { try p.destroy(fields: ["item": "other"]) }

        // The item is not synchronisable.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        // Note: the file-based login keychain does not report kSecAttrAccessible back.
        #expect(((result as? [String: Any])?[kSecAttrSynchronizable as String] as? Bool ?? false) == false)
    }

    @Test func legacyKeychainItemWithoutFieldsStillWorks() throws {
        let service = "com.fbrogno.macauth.tests.\(UUID().uuidString)"
        let p = KeychainProtector(service: service, account: "vault-key")
        defer { cleanup(p) }
        let key = SymmetricKey(size: .bits256)
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "vault-key", kSecAttrSynchronizable as String: false]
        q[kSecValueData as String] = keyBytes(key)
        #expect(SecItemAdd(q as CFDictionary, nil) == errSecSuccess)
        #expect(keyBytes(try p.unwrap(fields: [:])) == keyBytes(key))
        try p.destroy(fields: [:])
        #expect(throws: ProtectorError.keyNotFound) { try p.unwrap(fields: [:]) }
    }

    @Test func errorClassification() {
        func mapped(_ domain: String, _ code: Int) -> ProtectorError {
            SecureEnclaveProtector.map(NSError(domain: domain, code: code))
        }
        #expect(mapped(NSOSStatusErrorDomain, -25308) == .interactionNotAllowed)    // errSecInteractionNotAllowed
        #expect(mapped(NSOSStatusErrorDomain, -128) == .userCancelled)              // errSecUserCanceled
        #expect(mapped(NSOSStatusErrorDomain, -25293) == .authenticationFailed)     // errSecAuthFailed
        #expect(mapped(NSOSStatusErrorDomain, -25300) == .secureEnclaveFailure(-25300))
        #expect(mapped("com.apple.LocalAuthentication", -2) == .userCancelled)
        #expect(mapped("com.apple.LocalAuthentication", -1) == .authenticationFailed)
        #expect(mapped("com.apple.LocalAuthentication", -1004) == .interactionNotAllowed)
        #expect(mapped("com.apple.LocalAuthentication", -8) == .secureEnclaveFailure(-8))   // lockout: no verdict
        #expect(KeychainProtector.map(errSecInteractionNotAllowed) == .interactionNotAllowed)
        #expect(KeychainProtector.map(errSecItemNotFound) == .keyNotFound)
    }

    /// Without `.userPresence` no prompt appears, so this runs unattended. The production flags
    /// (`SecureEnclaveProtector.defaultAccessControlFlags`) are deliberately not exercised here.
    @Test(.enabled(if: enclaveUsable))
    func secureEnclaveWrapUnwrapWithoutUserPresence() throws {
        let p = SecureEnclaveProtector(accessControlFlags: [.privateKeyUsage])
        let key = SymmetricKey(size: .bits256)
        let fields = try p.wrap(vaultKey: key)
        #expect(Set(fields.keys) == ["keyBlob", "ephemeralPublicKey", "salt", "wrapped"])
        #expect(keyBytes(try p.unwrap(fields: fields)) == keyBytes(key))
        var broken = fields
        broken["wrapped"] = flipByte(inBase64: fields["wrapped"]!)
        #expect(throws: ProtectorError.dataCorrupted) { try p.unwrap(fields: broken) }
        #expect(throws: ProtectorError.dataCorrupted) { try p.unwrap(fields: [:]) }
    }

    @Test func secureEnclaveDefaultFlagsMatchDesign() {
        #expect(SecureEnclaveProtector.defaultAccessControlFlags == [.privateKeyUsage, .userPresence])
    }

    @Test(.enabled(if: enclaveUsable))
    func vaultWithSecureEnclaveProtector() async throws {
        let dir = try tempDirectory()
        let store = VaultStore(url: dir.appendingPathComponent("vault.json"))
        let p = SecureEnclaveProtector(accessControlFlags: [.privateKeyUsage])
        let data = sampleVault()
        try await store.create(contents: data, protector: p)
        await store.lock()
        try await store.load()
        #expect(await store.protectorIdentifier == "secure-enclave")
        #expect(try await store.unlock(using: p) == data)
    }
}
