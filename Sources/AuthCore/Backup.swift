import CommonCrypto
import CryptoKit
import Foundation

/// Encrypted backup file (`.macauth`). Format: see `docs/backup-format.md`.
public enum BackupFile {
    public static let fileExtension = "macauth"
    public static let minimumPasswordLength = 10
    public static let defaultIterations = 600_000
    /// Files outside this range are rejected so a crafted file can neither weaken nor hang the app.
    public static let acceptedIterations = 100_000...10_000_000

    static let formatName = "macauth-backup"
    static let kdfName = "pbkdf2-hmac-sha256"
    static let cipherName = "aes-256-gcm"

    struct Header: Codable {
        struct KDF: Codable {
            var name: String
            var iterations: Int
            var salt: String
        }
        var format: String
        var version: Int
        var kdf: KDF
        var cipher: String
        var nonce: String
        var ciphertext: String
        var tag: String
    }

    public static func encrypt(_ contents: VaultData, password: String) throws -> Data {
        try encrypt(contents, password: password, iterations: defaultIterations)
    }

    public static func decrypt(_ file: Data, password: String) throws -> VaultData {
        try decrypt(file, password: password, acceptedIterations: acceptedIterations)
    }

    // Internal variants let tests use a small iteration count.

    static func encrypt(_ contents: VaultData, password: String, iterations: Int) throws -> Data {
        try encryptRaw(try contents.withoutSecuritySettings.encoded(), password: password, iterations: iterations)
    }

    /// Seals an already encoded payload. Only `encrypt` strips the security settings; tests use this to craft a file
    /// that carries them anyway.
    static func encryptRaw(_ payload: Data, password: String, iterations: Int) throws -> Data {
        guard password.count >= minimumPasswordLength else {
            throw BackupError.passwordTooShort(minimum: minimumPasswordLength)
        }
        let salt = randomBytes(16)
        let nonce = AES.GCM.Nonce()
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let aad = authenticatedHeader(iterations: iterations, saltBase64: salt.base64EncodedString())
        let box = try AES.GCM.seal(payload, using: key, nonce: nonce, authenticating: aad)
        let header = Header(
            format: formatName, version: 1,
            kdf: .init(name: kdfName, iterations: iterations, salt: salt.base64EncodedString()),
            cipher: cipherName, nonce: Data(nonce).base64EncodedString(),
            ciphertext: box.ciphertext.base64EncodedString(), tag: box.tag.base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(header)
    }

    static func decrypt(_ file: Data, password: String, acceptedIterations: ClosedRange<Int>) throws -> VaultData {
        guard file.count <= Limits.maxFileBytes else { throw BackupError.notABackup }
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: file) } catch { throw BackupError.notABackup }
        guard header.format == formatName else { throw BackupError.notABackup }
        guard header.version == 1 else { throw BackupError.unsupportedVersion(header.version) }
        guard header.kdf.name == kdfName, header.cipher == cipherName,
              acceptedIterations.contains(header.kdf.iterations),
              let salt = Data(base64Encoded: header.kdf.salt), (16...64).contains(salt.count),
              let nonceData = Data(base64Encoded: header.nonce), nonceData.count == 12,
              let ciphertext = Data(base64Encoded: header.ciphertext),
              let tag = Data(base64Encoded: header.tag), tag.count == 16
        else { throw BackupError.unsupportedParameters }
        let plain: Data
        do {
            let key = try deriveKey(password: password, salt: salt, iterations: header.kdf.iterations)
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData), ciphertext: ciphertext, tag: tag)
            plain = try AES.GCM.open(box, using: key, authenticating:
                authenticatedHeader(iterations: header.kdf.iterations, saltBase64: salt.base64EncodedString()))
        } catch {
            throw BackupError.wrongPasswordOrCorrupt
        }
        do { return try VaultData.decoded(from: plain).withoutSecuritySettings } catch { throw BackupError.wrongPasswordOrCorrupt }
    }

    /// AAD: the header fields that decide how the file is read, as one canonical text.
    static func authenticatedHeader(iterations: Int, saltBase64: String) -> Data {
        Data("\(formatName)\n1\n\(kdfName)\n\(iterations)\n\(saltBase64)\n\(cipherName)".utf8)
    }

    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        // NFC so that the same password typed on different keyboards/OS versions matches.
        let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBufferPointer { pw in
            salt.withUnsafeBytes { s in
                pw.withMemoryRebound(to: Int8.self) { pwc in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwc.baseAddress, pwc.count,
                                         s.bindMemory(to: UInt8.self).baseAddress, s.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         &derived, derived.count)
                }
            }
        }
        guard status == kCCSuccess else { throw BackupError.unsupportedParameters }
        defer { for i in derived.indices { derived[i] = 0 } }
        return SymmetricKey(data: derived)
    }

    private static func randomBytes(_ n: Int) -> Data {
        Data(SymmetricKey(size: SymmetricKeySize(bitCount: n * 8)).withUnsafeBytes { Array($0) })
    }
}
