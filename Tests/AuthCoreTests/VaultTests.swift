import CryptoKit
import Foundation
import Testing
@testable import AuthCore

struct VaultTests {
    func makeStore() throws -> (VaultStore, URL) {
        let dir = try tempDirectory()
        let url = dir.appendingPathComponent("Support/MacAuth/vault.json")   // directories are created on demand
        return (VaultStore(url: url), url)
    }

    func readJSON(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    @Test func roundTripAndLifecycle() async throws {
        let (store, url) = try makeStore()
        let protector = InMemoryProtector()
        #expect(await store.state == .unloaded)
        #expect(try await store.load() == .empty)
        #expect(await store.contents == nil)
        let data = sampleVault()
        try await store.create(contents: data, protector: protector)
        #expect(await store.state == .unlocked)
        #expect(await store.contents == data)

        // The file contains no plain text of the data.
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains("alice") && !raw.contains("Example") && !raw.contains("Büro"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        await store.lock()
        #expect(await store.state == .locked)
        #expect(await store.contents == nil)
        await #expect(throws: VaultError.locked) { try await store.save(data) }

        // A fresh store (app restart) reads and unlocks it.
        let again = VaultStore(url: url)
        #expect(try await again.load() == .locked)
        #expect(await again.protectorIdentifier == "memory")
        #expect(try await again.unlock(using: protector) == data)
        #expect(await again.state == .unlocked)
    }

    @Test func saveReplacesAtomicallyAndKeepsPreviousGeneration() async throws {
        let (store, url) = try makeStore()
        let protector = InMemoryProtector()
        var data = sampleVault()
        try await store.create(contents: data, protector: protector)
        #expect(!(await store.hasPreviousGeneration))
        let first = data
        data.accounts.append(makeAccount("second", secret: "second-secret-0123456789"))
        try await store.save(data)
        #expect(await store.hasPreviousGeneration)
        let second = data
        data.accounts.append(makeAccount("third", secret: "third-secret-0123456789"))
        try await store.save(data)

        // vault.previous.json is the generation before the last save and can be opened with the same key.
        let previousURL = store.previousURL
        #expect(previousURL.lastPathComponent == "vault.previous.json")
        let previous = VaultStore(url: previousURL)
        try await previous.load()
        #expect(try await previous.unlock(using: protector) == second)
        #expect(second != first)

        // No temp files are left behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted()
        #expect(names == ["vault.json", "vault.previous.json"])
    }

    @Test func recoversPreviousGenerationAfterCorruption() async throws {
        let (store, url) = try makeStore()
        let protector = InMemoryProtector()
        var data = sampleVault()
        try await store.create(contents: data, protector: protector)
        let first = data
        data.accounts.removeLast()
        try await store.save(data)
        await store.lock()

        try Data("garbage".utf8).write(to: url)
        await #expect(throws: VaultError.corrupted) { try await store.load() }
        try await store.recoverPreviousGeneration()
        #expect(await store.state == .locked)
        #expect(try await store.unlock(using: protector) == first)
        // The unreadable file is kept unchanged as vault.replaced-*.json.
        let replaced = await store.replacedFiles()
        #expect(replaced.count == 1)
        #expect(try Data(contentsOf: replaced[0].url) == Data("garbage".utf8))
        #expect(replaced[0].protectorIdentifier == nil)

        let (empty, _) = try makeStore()
        await #expect(throws: VaultError.noPreviousGeneration) { try await empty.recoverPreviousGeneration() }
    }

    @Test func fallsBackToPreviousFileIfCurrentIsMissing() async throws {
        let (store, url) = try makeStore()
        let protector = InMemoryProtector()
        let data = sampleVault()
        try await store.create(contents: data, protector: protector)
        try await store.save(data)
        try FileManager.default.removeItem(at: url)
        #expect(try await store.load() == .locked)
        #expect(await store.loadedFromPreviousGeneration)
        #expect(try await store.unlock(using: protector) == data)
    }

    @Test func wrongProtectorCannotUnlock() async throws {
        let (store, url) = try makeStore()
        try await store.create(contents: sampleVault(), protector: InMemoryProtector())
        let other = VaultStore(url: url)
        try await other.load()
        // Same kind of protector but another "device": the key cannot be unwrapped.
        await #expect(throws: VaultError.corrupted) { try await other.unlock(using: InMemoryProtector()) }
        // Different kind of protector.
        await #expect(throws: VaultError.protectorMismatch(stored: "memory")) {
            try await other.unlock(using: KeychainProtector(service: "unused", account: "unused"))
        }
        #expect(await other.state == .locked)
    }

    @Test func tamperedCiphertextAndTagAreRejected() async throws {
        let protector = InMemoryProtector()
        for field in ["ciphertext", "tag", "nonce"] {
            let (store, url) = try makeStore()
            try await store.create(contents: sampleVault(), protector: protector)
            await store.lock()
            var json = try readJSON(url)
            json[field] = flipByte(inBase64: json[field] as! String)
            try writeJSON(json, to: url)
            try await store.load()
            await #expect(throws: VaultError.corrupted, "tampered \(field)") { try await store.unlock(using: protector) }
        }
    }

    @Test func tamperedHeaderIsRejected() async throws {
        let protector = InMemoryProtector()
        // An extra protector field is ignored by the protector but covered by the AAD.
        let (store, url) = try makeStore()
        try await store.create(contents: sampleVault(), protector: protector)
        await store.lock()
        var json = try readJSON(url)
        var fields = json["protectorFields"] as! [String: String]
        fields["extra"] = "AAAA"
        json["protectorFields"] = fields
        try writeJSON(json, to: url)
        try await store.load()
        await #expect(throws: VaultError.corrupted) { try await store.unlock(using: protector) }

        // Tampered wrapped key.
        json = try readJSON(url)
        fields = json["protectorFields"] as! [String: String]
        fields["extra"] = nil
        fields["wrapped"] = flipByte(inBase64: fields["wrapped"]!)
        json["protectorFields"] = fields
        try writeJSON(json, to: url)
        try await store.load()
        await #expect(throws: VaultError.corrupted) { try await store.unlock(using: protector) }

        // Unknown version.
        json["version"] = 2
        try writeJSON(json, to: url)
        await #expect(throws: VaultError.unsupportedVersion(2)) { try await store.load() }

        // Malformed envelopes.
        try writeJSON(["version": 1, "protector": "memory"], to: url)
        await #expect(throws: VaultError.corrupted) { try await store.load() }
        try Data().write(to: url)
        await #expect(throws: VaultError.corrupted) { try await store.load() }
    }

    @Test func swappedProtectorNameIsDetected() async throws {
        // Renaming the protector in the file changes the AAD; with a protector that accepts the new name it still fails.
        struct Renamed: KeyProtector {
            let identifier = "renamed"
            let inner: InMemoryProtector
            func wrap(vaultKey: SymmetricKey) throws -> ProtectorFields { try inner.wrap(vaultKey: vaultKey) }
            func unwrap(fields: ProtectorFields) throws -> SymmetricKey { try inner.unwrap(fields: fields) }
        }
        let inner = InMemoryProtector()
        let (store, url) = try makeStore()
        try await store.create(contents: sampleVault(), protector: inner)
        await store.lock()
        var json = try readJSON(url)
        json["protector"] = "renamed"
        try writeJSON(json, to: url)
        try await store.load()
        await #expect(throws: VaultError.corrupted) { try await store.unlock(using: Renamed(inner: inner)) }
    }

    @Test func changeProtector() async throws {
        let (store, url) = try makeStore()
        let first = InMemoryProtector()
        let data = sampleVault()
        try await store.create(contents: data, protector: first)
        let second = InMemoryProtector()
        try await store.changeProtector(to: second)
        await store.lock()
        let reopened = VaultStore(url: url)
        try await reopened.load()
        await #expect(throws: VaultError.corrupted) { try await reopened.unlock(using: first) }
        #expect(try await reopened.unlock(using: second) == data)

        // Changing to another kind removes the old external secret.
        let service = "com.fbrogno.macauth.tests.\(UUID().uuidString)"
        let keychain = KeychainProtector(service: service, account: "vault-key")
        defer { for id in (try? keychain.ownedItemIDs()) ?? [] { try? keychain.destroyItem(id: id) } }
        try await reopened.changeProtector(to: keychain)
        #expect(await reopened.protectorIdentifier == "keychain")
        await reopened.lock()
        let third = VaultStore(url: url)
        try await third.load()
        #expect(try await third.unlock(using: keychain) == data)
    }

    @Test func createRefusesToOverwriteUnlessAsked() async throws {
        let (store, _) = try makeStore()
        let protector = InMemoryProtector()
        try await store.create(contents: sampleVault(), protector: protector)
        await #expect(throws: VaultError.alreadyExists) { try await store.create(protector: protector) }
        try await store.create(contents: VaultData(accounts: []), protector: protector, replacingExisting: true)
        #expect(await store.contents?.accounts.isEmpty == true)
    }

    @Test func destroyRemovesFiles() async throws {
        let (store, url) = try makeStore()
        try await store.create(contents: sampleVault(), protector: InMemoryProtector())
        try await store.save(sampleVault())
        try await store.destroy()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: store.previousURL.path))
        #expect(await store.state == .empty)
    }

    @Test func rejectsOversizedVaultFile() async throws {
        let (store, url) = try makeStore()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: Limits.maxFileBytes + 1).write(to: url)
        await #expect(throws: VaultError.corrupted) { try await store.load() }
    }
}
