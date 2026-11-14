import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Protector-specific data stored in the vault envelope (values are Base64 strings).
public typealias ProtectorFields = [String: String]

/// Holds the random 256-bit vault key. `wrap` is called once when a vault is created (or the protector
/// changes); `unwrap` on every unlock.
public protocol KeyProtector: Sendable {
    /// Stored in the envelope: `secure-enclave`, `keychain` or `memory`.
    var identifier: String { get }
    func wrap(vaultKey: SymmetricKey) throws -> ProtectorFields
    func unwrap(fields: ProtectorFields) throws -> SymmetricKey
    /// Removes the secret material that `fields` refer to and nothing else (keychain item). Default: nothing to do.
    /// `wrap` itself never deletes anything; callers delete old material only after the new file is safely written.
    func destroy(fields: ProtectorFields) throws
    /// Identifier of the external item `fields` refer to, if the protector keeps one outside the envelope.
    func referencedItemID(in fields: ProtectorFields) -> String?
    /// All external items this protector's service holds (for orphan clean-up). Default: none.
    func ownedItemIDs() throws -> [String]
    func destroyItem(id: String) throws
}

extension KeyProtector {
    public func destroy(fields: ProtectorFields) throws {}
    public func referencedItemID(in fields: ProtectorFields) -> String? { nil }
    public func ownedItemIDs() throws -> [String] { [] }
    public func destroyItem(id: String) throws {}
}

private func field(_ fields: ProtectorFields, _ name: String) throws -> Data {
    guard let text = fields[name], let data = Data(base64Encoded: text) else { throw ProtectorError.dataCorrupted }
    return data
}

private func keyData(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

// MARK: - In memory (tests)

/// A stand-in for the device: wraps the vault key with its own master key. A different instance cannot unwrap.
public final class InMemoryProtector: KeyProtector, @unchecked Sendable {
    public let identifier = "memory"
    private let master: SymmetricKey

    public init(masterKey: SymmetricKey = SymmetricKey(size: .bits256)) {
        master = masterKey
    }

    public func wrap(vaultKey: SymmetricKey) throws -> ProtectorFields {
        let box = try ChaChaPoly.seal(keyData(vaultKey), using: master)
        return ["wrapped": box.combined.base64EncodedString()]
    }

    public func unwrap(fields: ProtectorFields) throws -> SymmetricKey {
        do {
            let box = try ChaChaPoly.SealedBox(combined: try field(fields, "wrapped"))
            return SymmetricKey(data: try ChaChaPoly.open(box, using: master))
        } catch {
            throw ProtectorError.dataCorrupted
        }
    }
}

// MARK: - Login keychain

/// Vault key as generic password in the login keychain, never synchronised, no data-protection keychain
/// (so no provisioning profile is needed).
///
/// Honest limits: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is set, but the file-based login keychain
/// does not enforce it (it is not even reported back on queries). The item is protected by the login keychain
/// only, and it can travel with Time Machine restores or Migration Assistant to another Mac, together with
/// the vault file. This protector is the weaker fallback; the Secure Enclave protector is the strong one.
///
/// Every `wrap` creates a NEW item named `<account>-<UUID>` (stored in the fields as `item`) and never deletes
/// anything; `unwrap` and `destroy(fields:)` touch exactly that item. Vaults written by an older version
/// have no `item` field and use the plain `account` name.
public struct KeychainProtector: KeyProtector {
    public let identifier = "keychain"
    public let service: String
    public let account: String

    public init(service: String = "com.fbrogno.macauth.vault-key", account: String = "vault-key") {
        self.service = service
        self.account = account
    }

    private func query(item: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: item,
         kSecAttrSynchronizable as String: false]
    }

    public func referencedItemID(in fields: ProtectorFields) -> String? { fields["item"] ?? account }

    private func item(in fields: ProtectorFields) throws -> String {
        let item = fields["item"] ?? account
        guard item == account || (item.hasPrefix(account + "-") && item.utf8.count <= 128) else {
            throw ProtectorError.dataCorrupted
        }
        return item
    }

    public func wrap(vaultKey: SymmetricKey) throws -> ProtectorFields {
        let item = "\(account)-\(UUID().uuidString)"
        var q = query(item: item)
        q[kSecValueData as String] = keyData(vaultKey)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.map(status) }
        return ["item": item]
    }

    public func unwrap(fields: ProtectorFields) throws -> SymmetricKey {
        var q = query(item: try item(in: fields))
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess else { throw Self.map(status) }
        guard let data = result as? Data, data.count == 32 else { throw ProtectorError.dataCorrupted }
        return SymmetricKey(data: data)
    }

    public func destroy(fields: ProtectorFields) throws {
        try destroyItem(id: try item(in: fields))
    }

    public func destroyItem(id: String) throws {
        let status = SecItemDelete(query(item: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.map(status) }
    }

    public func ownedItemIDs() throws -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrSynchronizable as String: false,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Self.map(status) }
        let rows = (result as? [[String: Any]]) ?? []
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0 == account || $0.hasPrefix(account + "-") }
    }

    static func map(_ status: OSStatus) -> ProtectorError {
        switch status {
        case errSecItemNotFound: .keyNotFound
        case errSecUserCanceled: .userCancelled
        case errSecAuthFailed: .authenticationFailed
        case errSecInteractionNotAllowed: .interactionNotAllowed
        default: .keychainFailure(status)
        }
    }
}

// MARK: - Secure Enclave

/// Vault key wrapped for a Secure Enclave P-256 key agreement key (ECDH, HKDF-SHA256, ChaCha20-Poly1305).
/// The envelope stores the enclave key blob (usable on this Mac only), an ephemeral public key, the HKDF
/// salt and the wrapped key. With `.userPresence`, unlocking needs Touch ID or the login password.
public struct SecureEnclaveProtector: KeyProtector, @unchecked Sendable {
    public let identifier = "secure-enclave"
    public static let defaultAccessControlFlags: SecAccessControlCreateFlags = [.privateKeyUsage, .userPresence]
    private static let info = Data("MacAuth vault key wrap v1".utf8)

    private let context: LAContext?
    private let flags: SecAccessControlCreateFlags

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    /// - Parameters:
    ///   - context: carries the localised reason shown in the Touch ID prompt (`localizedReason`).
    ///   - accessControlFlags: injectable so tests can run without a user prompt.
    public init(context: LAContext? = nil, accessControlFlags: SecAccessControlCreateFlags = defaultAccessControlFlags) {
        self.context = context
        self.flags = accessControlFlags
    }

    public func wrap(vaultKey: SymmetricKey) throws -> ProtectorFields {
        guard Self.isAvailable else { throw ProtectorError.secureEnclaveUnavailable }
        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &cfError) else {
            cfError?.release()
            throw ProtectorError.invalidAccessControl
        }
        do {
            let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context)
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: enclaveKey.publicKey)
            let salt = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let wrapKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Self.info, outputByteCount: 32)
            let box = try ChaChaPoly.seal(keyData(vaultKey), using: wrapKey)
            return ["keyBlob": enclaveKey.dataRepresentation.base64EncodedString(),
                    "ephemeralPublicKey": ephemeral.publicKey.x963Representation.base64EncodedString(),
                    "salt": salt.base64EncodedString(),
                    "wrapped": box.combined.base64EncodedString()]
        } catch {
            throw Self.map(error)
        }
    }

    public func unwrap(fields: ProtectorFields) throws -> SymmetricKey {
        guard Self.isAvailable else { throw ProtectorError.secureEnclaveUnavailable }
        let blob = try field(fields, "keyBlob")
        let publicKeyData = try field(fields, "ephemeralPublicKey")
        let salt = try field(fields, "salt")
        let combined = try field(fields, "wrapped")
        guard blob.count <= 4096, salt.count <= 64 else { throw ProtectorError.dataCorrupted }
        let ephemeral: P256.KeyAgreement.PublicKey
        let box: ChaChaPoly.SealedBox
        do {
            ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: publicKeyData)
            box = try ChaChaPoly.SealedBox(combined: combined)
        } catch {
            throw ProtectorError.dataCorrupted
        }
        let wrapKey: SymmetricKey
        do {
            let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob, authenticationContext: context)
            let shared = try enclaveKey.sharedSecretFromKeyAgreement(with: ephemeral)
            wrapKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Self.info, outputByteCount: 32)
        } catch {
            throw Self.map(error)
        }
        do {
            return SymmetricKey(data: try ChaChaPoly.open(box, using: wrapKey))
        } catch {
            throw ProtectorError.dataCorrupted
        }
    }

    /// Classification of Secure Enclave / LocalAuthentication errors. The core never declares a key permanently
    /// unusable; that decision belongs to the user (restore from backup).
    /// - `LAError.userCancel/systemCancel/appCancel`, `errSecUserCanceled` (-128): `userCancelled`.
    /// - `LAError.authenticationFailed`, `errSecAuthFailed` (-25293): `authenticationFailed` (wrong finger/password).
    /// - `errSecInteractionNotAllowed` (-25308), `LAError.notInteractive`: `interactionNotAllowed`, temporary
    ///   (no GUI session, locked keychain); retry later.
    /// - Everything else (lockout, no passcode, missing key, other OSStatus): `secureEnclaveFailure(code)`,
    ///   reported as-is without a verdict.
    static func map(_ error: Error) -> ProtectorError {
        let ns = error as NSError
        if ns.domain == LAError.errorDomain {
            switch LAError.Code(rawValue: ns.code) {
            case .userCancel, .systemCancel, .appCancel: return .userCancelled
            case .authenticationFailed: return .authenticationFailed
            case .notInteractive: return .interactionNotAllowed
            default: return .secureEnclaveFailure(ns.code)
            }
        }
        switch ns.code {
        case Int(errSecUserCanceled): return .userCancelled
        case Int(errSecAuthFailed): return .authenticationFailed
        case Int(errSecInteractionNotAllowed): return .interactionNotAllowed
        default: return .secureEnclaveFailure(ns.code)
        }
    }
}
