import CryptoKit
import Foundation

public enum VaultState: Equatable, Sendable {
    /// `load()` has not been called yet.
    case unloaded
    /// No vault file exists (first start).
    case empty
    case locked
    case unlocked
}

struct VaultEnvelope: Codable {
    var version: Int
    var protector: String
    var protectorFields: ProtectorFields
    var nonce: String
    var ciphertext: String
    var tag: String

    /// The authenticated header: everything except nonce, ciphertext and tag, as one canonical text.
    static func authenticatedHeader(version: Int, protector: String, fields: ProtectorFields) -> Data {
        var text = "macauth-vault\n\(version)\n\(protector)\n"
        for key in fields.keys.sorted() { text += "\(key)=\(fields[key]!)\n" }
        return Data(text.utf8)
    }

    var aad: Data { Self.authenticatedHeader(version: version, protector: protector, fields: protectorFields) }
}

/// Holds key bytes in memory that is overwritten on `wipe()` (best effort: copies made by CryptoKit stay).
final class SecretBuffer: @unchecked Sendable {
    private let pointer: UnsafeMutableRawBufferPointer

    init(_ key: SymmetricKey) {
        let bytes = key.withUnsafeBytes { Array($0) }
        count = bytes.count
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(bytes.count, 1), alignment: 1)
        bytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
        pointer = buffer
    }

    private let count: Int
    var key: SymmetricKey { SymmetricKey(data: UnsafeRawBufferPointer(rebasing: pointer[0..<count])) }

    func wipe() {
        memset_s(pointer.baseAddress, pointer.count, 0, pointer.count)
    }

    deinit {
        wipe()
        pointer.deallocate()
    }
}

/// The encrypted vault file: load, unlock, lock, save (atomic, keeps the previous generation), change protector.
///
/// `unlock`, `create` and `changeProtector` can wait for the user (Touch ID); they run the protector off the
/// actor so other work is not blocked, but call them from a task, not from a synchronous UI path.
public actor VaultStore {
    public static let currentVersion = 1

    public nonisolated let url: URL
    public nonisolated var previousURL: URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base).previous" : "\(base).previous.\(ext)")
    }
    private nonisolated var corruptURL: URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base).corrupt" : "\(base).corrupt.\(ext)")
    }

    public private(set) var state: VaultState = .unloaded
    /// Identifier of the protector the vault file asks for (`secure-enclave`, `keychain`, `memory`).
    public var protectorIdentifier: String? { envelope?.protector }
    /// The decrypted data while unlocked.
    public private(set) var contents: VaultData?
    /// True if `load()` found no current file and fell back to the previous generation.
    public private(set) var loadedFromPreviousGeneration = false

    private var envelope: VaultEnvelope?
    private var keyBuffer: SecretBuffer?
    private var protector: (any KeyProtector)?

    public init(url: URL) {
        self.url = url
    }

    public var hasPreviousGeneration: Bool { FileManager.default.fileExists(atPath: previousURL.path) }

    // MARK: Load / lock

    /// Reads the vault file header (no decryption). Locks if unlocked.
    @discardableResult
    public func load() throws -> VaultState {
        lock()
        loadedFromPreviousGeneration = false
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            envelope = try Self.readEnvelope(at: url)
        } else if fm.fileExists(atPath: previousURL.path) {
            envelope = try Self.readEnvelope(at: previousURL)
            loadedFromPreviousGeneration = true
        } else {
            envelope = nil
            state = .empty
            return .empty
        }
        state = .locked
        return .locked
    }

    /// Forgets the key and the decrypted data.
    public func lock() {
        keyBuffer?.wipe()
        keyBuffer = nil
        contents = nil
        protector = nil
        if state == .unlocked { state = .locked }
    }

    // MARK: Create / unlock

    /// Creates a new vault with a fresh vault key. The vault is unlocked afterwards.
    public func create(contents: VaultData = VaultData(), protector: any KeyProtector, replacingExisting: Bool = false) async throws {
        if !replacingExisting, FileManager.default.fileExists(atPath: url.path) { throw VaultError.alreadyExists }
        let key = SymmetricKey(size: .bits256)
        let fields = try await Self.offload { try protector.wrap(vaultKey: key) }
        let sealed = try Self.seal(contents, key: key, protector: protector.identifier, fields: fields)
        try writeCurrent(sealed, keepPrevious: replacingExisting)
        lock()
        envelope = sealed
        keyBuffer = SecretBuffer(key)
        self.contents = contents
        self.protector = protector
        state = .unlocked
        loadedFromPreviousGeneration = false
    }

    /// Unlocks with the protector that matches the vault file. May show the Touch ID prompt.
    @discardableResult
    public func unlock(using protector: any KeyProtector) async throws -> VaultData {
        if state == .unlocked, let contents { return contents }
        guard let envelope else { throw VaultError.noVault }
        guard envelope.protector == protector.identifier else { throw VaultError.protectorMismatch(stored: envelope.protector) }
        let fields = envelope.protectorFields
        let key: SymmetricKey
        do {
            key = try await Self.offload { try protector.unwrap(fields: fields) }
        } catch ProtectorError.dataCorrupted {
            throw VaultError.corrupted
        }
        let data = try Self.open(envelope, key: key)
        keyBuffer = SecretBuffer(key)
        contents = data
        self.protector = protector
        state = .unlocked
        return data
    }

    // MARK: Save

    /// Seals and writes the data atomically; the file replaced becomes `vault.previous.json`.
    public func save(_ newContents: VaultData) throws {
        guard state == .unlocked, let keyBuffer, let envelope else { throw VaultError.locked }
        let sealed = try Self.seal(newContents, key: keyBuffer.key, protector: envelope.protector, fields: envelope.protectorFields)
        try writeCurrent(sealed, keepPrevious: true)
        self.envelope = sealed
        contents = newContents
    }

    /// Re-wraps the vault key with another protector (e.g. Secure Enclave to keychain) and rewrites the file.
    public func changeProtector(to newProtector: any KeyProtector) async throws {
        guard state == .unlocked, let keyBuffer, let envelope, let contents else { throw VaultError.locked }
        let key = keyBuffer.key
        let newFields = try await Self.offload { try newProtector.wrap(vaultKey: key) }
        let sealed = try Self.seal(contents, key: key, protector: newProtector.identifier, fields: newFields)
        do {
            try writeCurrent(sealed, keepPrevious: true)
        } catch {
            try? newProtector.destroy(fields: newFields)
            throw error
        }
        // Same identifier means same storage (e.g. one keychain item), which `wrap` already replaced.
        if let old = protector, old.identifier != newProtector.identifier {
            try? old.destroy(fields: envelope.protectorFields)
        }
        self.envelope = sealed
        protector = newProtector
    }

    // MARK: Recovery / removal

    /// If the current file is unreadable, puts the previous generation in its place (the bad file is kept as
    /// `vault.corrupt.json`) and reloads. Throws `noPreviousGeneration` if there is none.
    public func recoverPreviousGeneration() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: previousURL.path) else { throw VaultError.noPreviousGeneration }
        let previous = try Self.readEnvelope(at: previousURL)
        lock()
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: corruptURL)
            try? fm.moveItem(at: url, to: corruptURL)
        }
        try writeCurrent(previous, keepPrevious: false)
        try load()
    }

    /// Deletes the vault files and, if unlocked, the protector's external secret. Irreversible.
    public func destroy() throws {
        let fm = FileManager.default
        if let envelope, let protector { try? protector.destroy(fields: envelope.protectorFields) }
        lock()
        for u in [url, previousURL] where fm.fileExists(atPath: u.path) {
            do { try fm.removeItem(at: u) } catch { throw VaultError.ioFailure(error.localizedDescription) }
        }
        envelope = nil
        state = .empty
    }

    // MARK: Internals

    private static func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    private func writeCurrent(_ sealed: VaultEnvelope, keepPrevious: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(sealed)
        do {
            if keepPrevious, FileManager.default.fileExists(atPath: url.path),
               let old = try? Data(contentsOf: url), (try? Self.decodeEnvelope(old)) != nil {
                try AtomicFile.write(old, to: previousURL)
            }
            try AtomicFile.write(data, to: url)
        } catch let e as VaultError {
            throw e
        } catch {
            throw VaultError.ioFailure(error.localizedDescription)
        }
    }

    static func seal(_ contents: VaultData, key: SymmetricKey, protector: String, fields: ProtectorFields) throws -> VaultEnvelope {
        let aad = VaultEnvelope.authenticatedHeader(version: currentVersion, protector: protector, fields: fields)
        let box = try ChaChaPoly.seal(try contents.encoded(), using: key, nonce: ChaChaPoly.Nonce(), authenticating: aad)
        return VaultEnvelope(version: currentVersion, protector: protector, protectorFields: fields,
                             nonce: Data(box.nonce).base64EncodedString(),
                             ciphertext: box.ciphertext.base64EncodedString(), tag: box.tag.base64EncodedString())
    }

    static func open(_ envelope: VaultEnvelope, key: SymmetricKey) throws -> VaultData {
        guard let nonce = Data(base64Encoded: envelope.nonce), let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let tag = Data(base64Encoded: envelope.tag) else { throw VaultError.corrupted }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            let plain = try ChaChaPoly.open(box, using: key, authenticating: envelope.aad)
            return try VaultData.decoded(from: plain)
        } catch {
            throw VaultError.corrupted
        }
    }

    static func readEnvelope(at url: URL) throws -> VaultEnvelope {
        let data: Data
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            guard size <= Limits.maxFileBytes else { throw VaultError.corrupted }
            data = try Data(contentsOf: url)
        } catch let e as VaultError {
            throw e
        } catch {
            throw VaultError.ioFailure(error.localizedDescription)
        }
        return try decodeEnvelope(data)
    }

    static func decodeEnvelope(_ data: Data) throws -> VaultEnvelope {
        let envelope: VaultEnvelope
        do { envelope = try JSONDecoder().decode(VaultEnvelope.self, from: data) } catch { throw VaultError.corrupted }
        guard envelope.version == currentVersion else { throw VaultError.unsupportedVersion(envelope.version) }
        guard !envelope.protector.isEmpty, envelope.protector.utf8.count <= 64,
              envelope.protectorFields.count <= Limits.maxEnvelopeFields,
              envelope.protectorFields.allSatisfy({ $0.key.utf8.count <= 64 && $0.value.utf8.count <= Limits.maxEnvelopeFieldBytes }),
              Data(base64Encoded: envelope.nonce)?.count == 12,
              Data(base64Encoded: envelope.tag)?.count == 16,
              Data(base64Encoded: envelope.ciphertext) != nil
        else { throw VaultError.corrupted }
        return envelope
    }
}

enum AtomicFile {
    /// Writes to a temp file in the same directory (mode 0600), fsyncs, then renames over the target.
    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw VaultError.ioFailure(error.localizedDescription)
        }
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw VaultError.ioFailure(String(cString: strerror(errno))) }
        var failure: String?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = String(cString: strerror(errno))
                    return
                }
                offset += n
            }
        }
        if failure == nil, fsync(fd) != 0 { failure = String(cString: strerror(errno)) }
        close(fd)
        if failure == nil, rename(temp.path, url.path) != 0 { failure = String(cString: strerror(errno)) }
        if let failure {
            unlink(temp.path)
            throw VaultError.ioFailure(failure)
        }
    }
}
