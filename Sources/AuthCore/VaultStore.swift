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

struct VaultEnvelope: Codable, Equatable {
    var version: Int
    var protector: String
    var protectorFields: ProtectorFields
    /// Whether opening the vault needs a fresh device-owner authentication in the app (matters for protectors that
    /// do not ask by themselves, i.e. the keychain). Part of the authenticated header; absent in older files, where
    /// it counts as "required". Flipping, adding or removing it makes the vault fail to open.
    var appLock: Bool?
    var nonce: String
    var ciphertext: String
    var tag: String

    /// The authenticated header: everything except nonce, ciphertext and tag, as one canonical text.
    /// `appLock` adds a line only when present, so files without it keep their original header.
    static func authenticatedHeader(version: Int, protector: String, fields: ProtectorFields, appLock: Bool? = nil) -> Data {
        var text = "macauth-vault\n\(version)\n\(protector)\n"
        for key in fields.keys.sorted() { text += "\(key)=\(fields[key]!)\n" }
        if let appLock { text += "applock=\(appLock ? 1 : 0)\n" }
        return Data(text.utf8)
    }

    var aad: Data { Self.authenticatedHeader(version: version, protector: protector, fields: protectorFields, appLock: appLock) }
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

/// A vault file that was set aside (never deleted automatically) when something replaced it.
public struct ReplacedVaultFile: Sendable, Equatable {
    public var url: URL
    /// When it was set aside (from the file name, UTC).
    public var date: Date
    /// `secure-enclave`, `keychain`, `memory`; nil if the file is not a readable envelope.
    public var protectorIdentifier: String?
}

/// The encrypted vault file: load, unlock, lock, save (atomic, keeps the previous generation), change protector.
///
/// `unlock`, `create` and `changeProtector` can wait for the user (Touch ID); they run the protector off the
/// actor so other work is not blocked, but call them from a task, not from a synchronous UI path.
///
/// Files next to `vault.json`:
/// - `vault.previous.json`: the generation before the last `save`, same vault key. Removed by `changeProtector`
///   (it hangs on the old key).
/// - `vault.replaced-<UTC>.json`: byte-for-byte copies of files that were replaced (`create(replacingExisting:)`,
///   `recoverPreviousGeneration`, `restoreReplaced`, or a foreign file found at save time). Never deleted
///   automatically, their key material is never touched.
public actor VaultStore {
    public static let currentVersion = 1

    public nonisolated let url: URL
    public nonisolated var previousURL: URL { sibling(".previous") }

    public private(set) var state: VaultState = .unloaded
    /// Identifier of the protector the vault file asks for (`secure-enclave`, `keychain`, `memory`).
    public var protectorIdentifier: String? { envelope?.protector }
    /// True if the app must ask for Touch ID / password before using the vault key. Read from the file header
    /// before unlocking (a manipulated value cannot open the vault: the header is authenticated). Files
    /// without the field, and no file at all, count as "required".
    /// After a restore or recovery it is always "required" until the first unlock has re-sealed the vault (or the user
    /// switched the lock off again in the unlocked app), whatever the restored file's header says.
    public var requiresAppAuthentication: Bool { pendingAuthentication || (envelope?.appLock ?? true) }
    /// True from a restore/recovery of a vault file until the first successful unlock after it. Backed by a marker
    /// file next to the vault, so it survives a restart of the app.
    public private(set) var pendingAuthentication = false
    /// The decrypted data while unlocked.
    public private(set) var contents: VaultData?
    /// True if `load()` found no current file and fell back to the previous generation.
    public private(set) var loadedFromPreviousGeneration = false
    /// Increases on every `lock()`. A caller that started `unlock`/`create`/`changeProtector` can compare the
    /// value before and after and discard late results.
    public private(set) var lockGeneration = 0

    private var envelope: VaultEnvelope?
    private var keyBuffer: SecretBuffer?
    private var protector: (any KeyProtector)?
    nonisolated var pendingMarkerURL: URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).auth-required")
    }
    /// Bytes of the vault file as this store last read or wrote them; anything else on disk is foreign.
    private var lastKnownBytes: Data?

    public init(url: URL) {
        self.url = url
    }

    /// Live file-system state, not remembered from `load()`.
    public var hasPreviousGeneration: Bool { FileManager.default.fileExists(atPath: previousURL.path) }

    nonisolated func sibling(_ infix: String, suffix: String = "") -> URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent(ext.isEmpty ? "\(base)\(infix)\(suffix)" : "\(base)\(infix)\(suffix).\(ext)")
    }

    // MARK: Load / lock

    /// Reads the vault file header (no decryption). Locks if unlocked. On failure the state is `.unloaded`.
    @discardableResult
    public func load() throws -> VaultState {
        lock()
        envelope = nil
        lastKnownBytes = nil
        state = .unloaded
        loadedFromPreviousGeneration = false
        let fm = FileManager.default
        pendingAuthentication = fm.fileExists(atPath: pendingMarkerURL.path)
        if fm.fileExists(atPath: url.path) {
            let (env, bytes) = try Self.readEnvelope(at: url)
            envelope = env
            lastKnownBytes = bytes
        } else if fm.fileExists(atPath: previousURL.path) {
            envelope = try Self.readEnvelope(at: previousURL).0
            loadedFromPreviousGeneration = true
            pendingAuthentication = true   // a fallback to an older generation counts as a recovery
        } else {
            state = .empty
            return .empty
        }
        state = .locked
        return .locked
    }

    /// Forgets the key and the decrypted data immediately (no suspension point).
    public func lock() {
        lockGeneration += 1
        clearSecrets()
        if state == .unlocked { state = .locked }
    }

    private func clearSecrets() {
        keyBuffer?.wipe()
        keyBuffer = nil
        contents = nil
        protector = nil
    }

    // MARK: Create / unlock

    /// Creates a new vault with a fresh vault key. The vault is unlocked afterwards.
    /// With `replacingExisting`, the existing file (and previous generation) is first copied unchanged to
    /// `vault.replaced-<UTC>.json`; its key material is not touched.
    public func create(contents: VaultData = VaultData(), protector: any KeyProtector, replacingExisting: Bool = false,
                       requireAppAuthentication: Bool = true) async throws {
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists, !replacingExisting { throw VaultError.alreadyExists }
        let generation = lockGeneration
        let key = SymmetricKey(size: .bits256)
        let fields = try await Self.offload { try protector.wrap(vaultKey: key) }
        // Order: new material exists -> file written atomically -> only then anything old may go. Here nothing old goes.
        do {
            guard generation == lockGeneration else { throw VaultError.locked }
            let sealed = try Self.seal(contents, key: key, protector: protector.identifier, fields: fields, appLock: requireAppAuthentication)
            if exists { try setAsideExisting(includePrevious: true) }
            let written = try writeCurrent(sealed, mode: .none)
            if exists { try? FileManager.default.removeItem(at: previousURL) }   // copied above; belongs to the old vault
            clearSecrets()
            envelope = sealed
            lastKnownBytes = written
            keyBuffer = SecretBuffer(key)
            self.contents = contents
            self.protector = protector
            state = .unlocked
            loadedFromPreviousGeneration = false
            clearPending()   // a newly created vault has a fresh key and the lock on
        } catch {
            try? protector.destroy(fields: fields)   // only the NEW material
            throw error
        }
    }

    /// Unlocks with the protector that matches the vault file. May show the Touch ID prompt.
    /// Always asks the protector, also when already unlocked (use it to re-authenticate); a protector that
    /// refuses never gets contents out.
    ///
    /// `appAuthenticated`: the app asked the user for Touch ID / password just before. A keychain vault that was
    /// restored with `appLock=false` in its header refuses to open without it (the keychain does not ask by itself).
    @discardableResult
    public func unlock(using protector: any KeyProtector, appAuthenticated: Bool = false) async throws -> VaultData {
        guard let envelope else { throw VaultError.noVault }
        guard envelope.protector == protector.identifier else { throw VaultError.protectorMismatch(stored: envelope.protector) }
        if pendingAuthentication, envelope.appLock == false, protector.identifier == "keychain", !appAuthenticated {
            throw VaultError.authenticationRequired
        }
        let generation = lockGeneration
        let fields = envelope.protectorFields
        let key: SymmetricKey
        do {
            key = try await Self.offload { try protector.unwrap(fields: fields) }
        } catch ProtectorError.dataCorrupted {
            throw VaultError.corrupted
        }
        // lock() ran while we waited, or the file's key material changed: drop the result.
        guard generation == lockGeneration, let current = self.envelope,
              current.protector == envelope.protector, current.protectorFields == fields else { throw VaultError.locked }
        let data = try Self.open(current, key: key)
        if state == .unlocked, let contents { return contents }
        keyBuffer = SecretBuffer(key)
        contents = data
        self.protector = protector
        state = .unlocked
        if pendingAuthentication { await finishRecovery(protector: protector) }
        return contents ?? data
    }

    /// First unlock after a restore or recovery: the restored vault gets the strict security settings of a fresh
    /// vault, and a header with `appLock=false` is replaced by `appLock=true` under a NEW vault key (the old key's
    /// previous generation, which still says `false`, is discarded). Best effort: if it fails, the vault stays
    /// "required" (flag and marker remain) and the next unlock tries again.
    private func finishRecovery(protector: any KeyProtector) async {
        guard state == .unlocked, let envelope, var data = contents else { return }
        let hadSettings = data.security != nil
        data.security = nil
        do {
            if envelope.appLock == false {
                contents = data
                try await changeProtector(to: protector, requireAppAuthentication: true)
            } else if hadSettings {
                try save(data)
            }
        } catch {
            return
        }
        clearPending()
    }

    // MARK: Save

    /// Seals and writes the data atomically; the file replaced becomes `vault.previous.json`.
    /// Runs without suspension points, so `lock()` cannot interleave.
    public func save(_ newContents: VaultData) throws {
        guard state == .unlocked, let keyBuffer, let envelope else { throw VaultError.locked }
        let sealed = try Self.seal(newContents, key: keyBuffer.key, protector: envelope.protector, fields: envelope.protectorFields, appLock: envelope.appLock)
        let written = try writeCurrent(sealed, mode: .rotate)
        self.envelope = sealed
        lastKnownBytes = written
        contents = newContents
    }

    /// Writes data that differs from the stored vault only in usage history (`lastUsedAt`). Unlike `save` it does NOT
    /// rotate `vault.previous.json`, so the previous generation keeps pointing at the state before the last real
    /// change. Callers treat a failure as nothing worth reporting (the note is simply written with the next change).
    public func saveUsage(_ newContents: VaultData) throws {
        guard state == .unlocked, let keyBuffer, let envelope else { throw VaultError.locked }
        let sealed = try Self.seal(newContents, key: keyBuffer.key, protector: envelope.protector, fields: envelope.protectorFields, appLock: envelope.appLock)
        let written = try writeCurrent(sealed, mode: .overwrite)
        self.envelope = sealed
        lastKnownBytes = written
        contents = newContents
    }

    /// Changes whether the app asks for authentication before using the vault key. Only while unlocked; the app
    /// must have authenticated freshly before lowering it. The value is sealed into the authenticated header.
    ///
    /// Switching it back ON from `false` creates a new vault key and discards the previous generation (as
    /// `changeProtector` does), so `vault.previous.json` with `appLock=false` under the same key cannot survive and
    /// be restored later. Switching it OFF is only possible while unlocked and also ends a pending-recovery state.
    public func setRequiresAppAuthentication(_ on: Bool) async throws {
        guard state == .unlocked, let keyBuffer, let envelope, let contents, let protector else { throw VaultError.locked }
        if on, envelope.appLock == false {
            try await changeProtector(to: protector, requireAppAuthentication: true)
            clearPending()
            return
        }
        let sealed = try Self.seal(contents, key: keyBuffer.key, protector: envelope.protector, fields: envelope.protectorFields, appLock: on)
        let written = try writeCurrent(sealed, mode: .rotate)
        self.envelope = sealed
        lastKnownBytes = written
        if !on { clearPending() }
    }

    private func clearPending() {
        pendingAuthentication = false
        try? FileManager.default.removeItem(at: pendingMarkerURL)
    }

    /// Switches to another protector with a NEW vault key: new material is created, the contents are sealed
    /// again and written atomically, and only after that succeeded the old material is destroyed and
    /// `vault.previous.json` (still on the old key) is removed. On any failure only the new material is removed
    /// and the vault stays as it was.
    public func changeProtector(to newProtector: any KeyProtector, requireAppAuthentication: Bool? = nil) async throws {
        guard state == .unlocked, let envelope, let contents else { throw VaultError.locked }
        let generation = lockGeneration
        let oldProtector = protector
        let newKey = SymmetricKey(size: .bits256)
        let newFields = try await Self.offload { try newProtector.wrap(vaultKey: newKey) }
        let sealed: VaultEnvelope
        let written: Data
        do {
            guard generation == lockGeneration, state == .unlocked else { throw VaultError.locked }
            sealed = try Self.seal(contents, key: newKey, protector: newProtector.identifier, fields: newFields,
                                   appLock: requireAppAuthentication ?? envelope.appLock)
            written = try writeCurrent(sealed, mode: .discardPrevious)
        } catch {
            try? newProtector.destroy(fields: newFields)
            throw error
        }
        try? FileManager.default.removeItem(at: previousURL)
        // The old key goes only if no remaining file (set-aside copies of this very vault) still points at it.
        if let oldProtector {
            if let id = oldProtector.referencedItemID(in: envelope.protectorFields) {
                if let refs = try? collectReferences(for: oldProtector), !refs.references(id) {
                    try? oldProtector.destroy(fields: envelope.protectorFields)
                }
            } else {
                try? oldProtector.destroy(fields: envelope.protectorFields)
            }
        }
        keyBuffer?.wipe()
        keyBuffer = SecretBuffer(newKey)
        self.envelope = sealed
        lastKnownBytes = written
        protector = newProtector
    }

    /// What the files in the vault folder (current, previous generation, every `vault.replaced-*`) refer to.
    /// Files that parse as an envelope (any version) contribute their field values and, for the protector's own
    /// kind, its item name (the legacy plain account name if the `item` field is missing). Anything else
    /// counts as opaque text and protects every id it mentions. An unreadable file throws.
    private struct KeyReferences {
        var ids = Set<String>()
        var opaqueTexts: [String] = []
        func references(_ id: String) -> Bool { ids.contains(id) || opaqueTexts.contains { $0.contains(id) } }
    }

    private func collectReferences(for protector: any KeyProtector) throws -> KeyReferences {
        var refs = KeyReferences()
        let files = [url, previousURL] + replacedFiles().map(\.url)
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file) else { throw VaultError.unreadableKeyFiles }
            if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let fields = json["protectorFields"] as? [String: String] {
                refs.ids.formUnion(fields.values)
                if json["protector"] as? String == protector.identifier, let id = protector.referencedItemID(in: fields) {
                    refs.ids.insert(id)
                }
            } else {
                refs.opaqueTexts.append(String(decoding: data, as: UTF8.self))   // also covers unknown shapes
            }
        }
        return refs
    }

    /// Deletes external key items (key-chain) that no file refers to (e.g. after a crash between writing and
    /// deleting). `alsoCheck` names further protectors whose services are cleaned too, independent of the
    /// current one (the app passes the keychain protector, so items left over from a keychain vault are found
    /// while the vault now uses the Secure Enclave).
    /// Only callable while unlocked, and only if the current file on disk decrypts with the unlocked key.
    /// If any candidate file cannot be read, nothing is deleted. Returns the number of items removed.
    @discardableResult
    public func removeOrphanedKeyMaterial(alsoCheck extra: [any KeyProtector] = []) async throws -> Int {
        guard state == .unlocked, let keyBuffer, let protector else { throw VaultError.locked }
        let disk = try Self.readEnvelope(at: url).0
        _ = try Self.open(disk, key: keyBuffer.key)
        var removed = 0
        for candidate in [protector] + extra {
            let refs = try collectReferences(for: candidate)
            for id in try candidate.ownedItemIDs() where !refs.references(id) {
                try candidate.destroyItem(id: id)
                removed += 1
            }
        }
        return removed
    }

    // MARK: Replaced files / recovery

    /// Files set aside by replacing operations, newest first.
    public func replacedFiles() -> [ReplacedVaultFile] {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let prefix = url.deletingPathExtension().lastPathComponent + ".replaced-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) && (ext.isEmpty || $0.hasSuffix("." + ext)) }.compactMap { name in
            let stamp = String(name.dropFirst(prefix.count).prefix(16))
            let file = dir.appendingPathComponent(name)
            let date = Self.stampFormatter().date(from: stamp)
                ?? (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
                ?? .distantPast
            var id: String?
            if let data = try? Data(contentsOf: file), data.count <= Limits.maxFileBytes,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                id = json["protector"] as? String
            }
            return ReplacedVaultFile(url: file, date: date, protectorIdentifier: id)
        }.sorted { $0.date > $1.date || ($0.date == $1.date && $0.url.lastPathComponent > $1.url.lastPathComponent) }
    }

    /// Makes a set-aside file the current vault again. The current file (and previous generation) is itself set
    /// aside first. Locks the store and reloads; `load()`'s error is thrown if the restored file is unreadable.
    public func restoreReplaced(_ file: ReplacedVaultFile) throws {
        guard replacedFiles().contains(where: { $0.url == file.url }) else { throw VaultError.replacedFileNotFound }
        let bytes: Data
        do { bytes = try Data(contentsOf: file.url) } catch { throw VaultError.ioFailure(error.localizedDescription) }
        lock()
        try markPendingAuthentication()
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists { try setAsideExisting(includePrevious: true) }
        try AtomicFile.write(bytes, to: url)
        try? FileManager.default.removeItem(at: file.url)
        if exists { try? FileManager.default.removeItem(at: previousURL) }
        try load()
    }

    /// Puts the previous generation in place of the current file (which is set aside as `vault.replaced-*`)
    /// and reloads. Throws `noPreviousGeneration` if there is none.
    public func recoverPreviousGeneration() throws {
        guard FileManager.default.fileExists(atPath: previousURL.path) else { throw VaultError.noPreviousGeneration }
        let (_, bytes) = try Self.readEnvelope(at: previousURL)
        lock()
        try markPendingAuthentication()
        if FileManager.default.fileExists(atPath: url.path) { try setAsideExisting(includePrevious: false) }
        try AtomicFile.write(bytes, to: url)
        try load()
    }

    /// Written before a restored file replaces the current one, so a restart cannot lose the "must authenticate" state.
    private func markPendingAuthentication() throws {
        do {
            try AtomicFile.write(Data("1".utf8), to: pendingMarkerURL)
        } catch let e as VaultError {
            throw e
        } catch {
            throw VaultError.ioFailure(error.localizedDescription)
        }
        pendingAuthentication = true
    }

    /// Deletes the vault files and, if unlocked, the protector's external secret. Irreversible.
    /// Set-aside files are kept.
    public func destroy() throws {
        let fm = FileManager.default
        if let envelope, let protector { try? protector.destroy(fields: envelope.protectorFields) }
        lock()
        for u in [url, previousURL] where fm.fileExists(atPath: u.path) {
            do { try fm.removeItem(at: u) } catch { throw VaultError.ioFailure(error.localizedDescription) }
        }
        envelope = nil
        lastKnownBytes = nil
        clearPending()
        state = .empty
    }

    // MARK: Internals

    private static func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    private static func stampFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }

    /// Copies the current file (and optionally the previous generation) byte for byte to `*.replaced-<UTC>*`.
    private func setAsideExisting(includePrevious: Bool) throws {
        let stamp = Self.stampFormatter().string(from: Date())
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try AtomicFile.write(try Data(contentsOf: url), to: freeName(stamp: stamp, suffix: ""))
            }
            if includePrevious, FileManager.default.fileExists(atPath: previousURL.path) {
                try AtomicFile.write(try Data(contentsOf: previousURL), to: freeName(stamp: stamp, suffix: "-previous"))
            }
        } catch let e as VaultError {
            throw e
        } catch {
            throw VaultError.ioFailure(error.localizedDescription)
        }
    }

    private func freeName(stamp: String, suffix: String) -> URL {
        var candidate = sibling(".replaced-\(stamp)", suffix: suffix)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = sibling(".replaced-\(stamp)", suffix: "\(suffix)-\(n)")
            n += 1
        }
        return candidate
    }

    private enum WriteMode {
        /// `save`: current becomes the previous generation.
        case rotate
        /// `saveUsage`: replaces the current file, the previous generation stays as it is.
        case overwrite
        /// `changeProtector`: previous generation is not kept (removed by the caller afterwards).
        case discardPrevious
        /// The caller took care of any existing file.
        case none
    }

    /// Writes the envelope. A file on disk that is not the one this store last wrote is foreign (another process,
    /// a restore, a manual copy) and is set aside unchanged before it is replaced. Order on disk: previous
    /// generation fully written first, then the current file replaced atomically.
    @discardableResult
    private func writeCurrent(_ sealed: VaultEnvelope, mode: WriteMode) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(sealed)
        do {
            if mode != .none, FileManager.default.fileExists(atPath: url.path) {
                let existing = try Data(contentsOf: url)
                if existing != lastKnownBytes {
                    try setAsideExisting(includePrevious: false)
                } else if mode == .rotate, (try? Self.decodeEnvelope(existing)) != nil {
                    try AtomicFile.write(existing, to: previousURL)
                }
            }
            try AtomicFile.write(data, to: url)
        } catch let e as VaultError {
            throw e
        } catch {
            throw VaultError.ioFailure(error.localizedDescription)
        }
        return data
    }

    static func seal(_ contents: VaultData, key: SymmetricKey, protector: String, fields: ProtectorFields, appLock: Bool? = true) throws -> VaultEnvelope {
        let aad = VaultEnvelope.authenticatedHeader(version: currentVersion, protector: protector, fields: fields, appLock: appLock)
        let box = try ChaChaPoly.seal(try contents.encoded(), using: key, nonce: ChaChaPoly.Nonce(), authenticating: aad)
        return VaultEnvelope(version: currentVersion, protector: protector, protectorFields: fields, appLock: appLock,
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

    static func readEnvelope(at url: URL) throws -> (VaultEnvelope, Data) {
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
        return (try decodeEnvelope(data), data)
    }

    static func decodeEnvelope(_ data: Data) throws -> VaultEnvelope {
        // Read the version first, so a newer file is reported as such even if its other fields changed shape.
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let version = json["version"] as? Int, version != currentVersion {
            throw VaultError.unsupportedVersion(version)
        }
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
        // F_FULLFSYNC flushes the drive cache; some file systems cannot do it, then plain fsync.
        if failure == nil, fcntl(fd, F_FULLFSYNC) == -1, fsync(fd) != 0 { failure = String(cString: strerror(errno)) }
        close(fd)
        if failure == nil, rename(temp.path, url.path) != 0 { failure = String(cString: strerror(errno)) }
        if let failure {
            unlink(temp.path)
            throw VaultError.ioFailure(failure)
        }
        // Persist the rename itself. Callers write one file completely (incl. this step) before the next, so the
        // previous generation is durable before the current file is replaced.
        let dirFD = open(dir.path, O_RDONLY)
        if dirFD >= 0 {
            if fcntl(dirFD, F_FULLFSYNC) == -1 { _ = fsync(dirFD) }
            close(dirFD)
        }
    }
}
