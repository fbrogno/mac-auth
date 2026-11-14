import CryptoKit
import Foundation
import Security
import Testing
@testable import AuthCore

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

    @Test func keychainWrapUnwrapDestroy() throws {
        let service = "com.fbrogno.macauth.tests.\(UUID().uuidString)"
        let p = KeychainProtector(service: service, account: "vault-key")
        defer { try? p.destroy(fields: [:]) }
        let key = SymmetricKey(size: .bits256)
        #expect(throws: ProtectorError.keyNotFound) { try p.unwrap(fields: [:]) }
        let fields = try p.wrap(vaultKey: key)
        #expect(fields.isEmpty)
        #expect(keyBytes(try p.unwrap(fields: fields)) == keyBytes(key))
        // Wrapping again replaces the item.
        let key2 = SymmetricKey(size: .bits256)
        _ = try p.wrap(vaultKey: key2)
        #expect(keyBytes(try p.unwrap(fields: [:])) == keyBytes(key2))

        // The item is device-bound and not synchronisable.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let attributes = result as? [String: Any]
        // Note: the file-based login keychain does not report kSecAttrAccessible back, so only the
        // synchronisation flag can be asserted here.
        #expect((attributes?[kSecAttrSynchronizable as String] as? Bool ?? false) == false)

        try p.destroy(fields: [:])
        #expect(throws: ProtectorError.keyNotFound) { try p.unwrap(fields: [:]) }
        try p.destroy(fields: [:])   // idempotent
    }

    /// Without `.userPresence` no prompt appears, so this runs unattended. The production flags
    /// (`SecureEnclaveProtector.defaultAccessControlFlags`) are deliberately not exercised here.
    @Test(.enabled(if: SecureEnclaveProtector.isAvailable))
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

    @Test(.enabled(if: SecureEnclaveProtector.isAvailable))
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
