import CryptoKit
import Foundation
import LocalAuthentication
import Testing
@testable import AuthCore

/// Fixes from the independent security review (M1 recovery authentication, M2 security settings in the vault,
/// N2 ACL, N3 counters, N4 CSV detection, N5 Apple Passwords round trip, update notice version).
struct ReviewFixTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

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

    func header(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// A keychain vault written with the unlock prompt off, then set aside by a replacement (as `vault.replaced-*`).
    func vaultWithPromptOffSetAside(_ store: VaultStore, _ keychain: KeychainProtector, security: SecuritySettings? = nil) async throws -> ReplacedVaultFile {
        var data = sampleVault()
        data.security = security
        try await store.create(contents: data, protector: keychain, requireAppAuthentication: false)
        try await store.save(data)                                  // a previous generation exists, also appLock=false
        await store.lock()
        try await store.create(contents: VaultData(), protector: InMemoryProtector(), replacingExisting: true)
        await store.lock()
        return try #require(await store.replacedFiles().first(where: { $0.protectorIdentifier == "keychain" }))
    }

    // MARK: M1 (b): restore always needs authentication first

    @Test func restoredSetAsideFileWithPromptOffIsStillRequired() async throws {
        let (store, url) = try makeStore()
        let keychain = testKeychain()
        defer { cleanup(keychain) }
        let aside = try await vaultWithPromptOffSetAside(store, keychain)
        try await store.restoreReplaced(aside)

        #expect(try header(url)["appLock"] as? Bool == false)        // the file itself says "off" ...
        #expect(await store.requiresAppAuthentication == true)       // ... the store says "required"
        // The keychain does not ask by itself, so the core refuses to open without proof of an authentication.
        await #expect(throws: VaultError.authenticationRequired) { try await store.unlock(using: keychain) }
        #expect(await store.state == .locked)
        _ = try await store.unlock(using: keychain, appAuthenticated: true)

        // The first unlock re-sealed the vault: lock on, new key, no previous generation with `appLock=false`.
        #expect(try header(url)["appLock"] as? Bool == true)
        #expect(await store.pendingAuthentication == false)
        #expect(!FileManager.default.fileExists(atPath: store.previousURL.path))
        #expect(!FileManager.default.fileExists(atPath: store.pendingMarkerURL.path))
        await store.lock()
        let reopened = VaultStore(url: url)
        try await reopened.load()
        #expect(await reopened.requiresAppAuthentication == true)
    }

    @Test func restoredPreviousGenerationWithPromptOffIsStillRequired() async throws {
        let (store, url) = try makeStore()
        let keychain = testKeychain()
        defer { cleanup(keychain) }
        let data = sampleVault()
        try await store.create(contents: data, protector: keychain, requireAppAuthentication: false)
        try await store.save(data)
        await store.lock()
        try await store.load()
        try await store.recoverPreviousGeneration()
        #expect(await store.requiresAppAuthentication == true)
        await #expect(throws: VaultError.authenticationRequired) { try await store.unlock(using: keychain) }
        #expect(try await store.unlock(using: keychain, appAuthenticated: true) == data)
        #expect(try header(url)["appLock"] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: store.previousURL.path))
    }

    @Test func pendingStateSurvivesARestartOfTheApp() async throws {
        let (store, url) = try makeStore()
        let keychain = testKeychain()
        defer { cleanup(keychain) }
        let aside = try await vaultWithPromptOffSetAside(store, keychain)
        try await store.restoreReplaced(aside)
        let restarted = VaultStore(url: url)
        try await restarted.load()
        #expect(await restarted.requiresAppAuthentication == true)
        await #expect(throws: VaultError.authenticationRequired) { try await restarted.unlock(using: keychain) }
    }

    @Test func fallbackToPreviousGenerationAtLoadCountsAsRecovery() async throws {
        let (store, url) = try makeStore()
        let p = InMemoryProtector()
        try await store.create(contents: sampleVault(), protector: p, requireAppAuthentication: false)
        try await store.save(sampleVault())
        await store.lock()
        try FileManager.default.removeItem(at: url)
        try await store.load()
        #expect(await store.loadedFromPreviousGeneration)
        #expect(await store.requiresAppAuthentication == true)
    }

    @Test func switchingTheLockOffAgainAfterARestoreIsPossibleWhenUnlocked() async throws {
        let (store, url) = try makeStore()
        let keychain = testKeychain()
        defer { cleanup(keychain) }
        let aside = try await vaultWithPromptOffSetAside(store, keychain)
        try await store.restoreReplaced(aside)
        _ = try await store.unlock(using: keychain, appAuthenticated: true)
        try await store.setRequiresAppAuthentication(false)          // the user, after a fresh authentication
        #expect(await store.requiresAppAuthentication == false)
        #expect(try header(url)["appLock"] as? Bool == false)
    }

    @Test func restoredVaultGetsStrictSecuritySettings() async throws {
        let (store, _) = try makeStore()
        let keychain = testKeychain()
        defer { cleanup(keychain) }
        let weak = SecuritySettings(autoLockMinutes: 0, protectScreen: false, hideCodes: false, clipboardClearSeconds: 0)
        let aside = try await vaultWithPromptOffSetAside(store, keychain, security: weak)
        try await store.restoreReplaced(aside)
        let opened = try await store.unlock(using: keychain, appAuthenticated: true)
        #expect(opened.security == nil)                              // strict defaults, not the old file's weak values
        #expect(opened.accounts.map(\.displayLabel) == sampleVault().accounts.map(\.displayLabel))
    }

    // MARK: M1 (c): switching the lock back on creates a new key and drops the previous generation

    @Test func lockOnAgainInKeychainModeRotatesKeyAndDropsPrevious() async throws {
        let (store, url) = try makeStore()
        let keychain = testKeychain()
        defer { cleanup(keychain) }
        let data = sampleVault()
        try await store.create(contents: data, protector: keychain, requireAppAuthentication: false)
        try await store.save(data)
        #expect(FileManager.default.fileExists(atPath: store.previousURL.path))   // previous: appLock=false, same key
        let oldItem = try #require((header(url)["protectorFields"] as? [String: String])?["item"])

        try await store.setRequiresAppAuthentication(true)
        #expect(await store.requiresAppAuthentication == true)
        #expect(!FileManager.default.fileExists(atPath: store.previousURL.path))
        let newItem = try #require((header(url)["protectorFields"] as? [String: String])?["item"])
        #expect(newItem != oldItem)
        #expect(try keychain.ownedItemIDs() == [newItem])            // the old key is gone with the old generation
        await store.lock()
        try await store.load()
        #expect(try await store.unlock(using: keychain) == data)
    }

    // MARK: M1 (a): authorization for recoveries

    @Test func recoveryAuthorizationIsBoundToGenerationTimeAndUse() {
        var auth = RecoveryAuthorization()
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(!auth.permits(generation: 1, now: t0))               // never granted
        auth.grant(generation: 1, now: t0)
        #expect(auth.permits(generation: 1, now: t0.addingTimeInterval(10)))
        #expect(!auth.permits(generation: 2, now: t0.addingTimeInterval(10)))                       // locked again meanwhile
        #expect(!auth.permits(generation: 1, now: t0.addingTimeInterval(RecoveryAuthorization.validity + 1)))
        #expect(!auth.permits(generation: 1, now: t0.addingTimeInterval(-5)))                       // clock went back
        auth.consume()
        #expect(!auth.permits(generation: 1, now: t0.addingTimeInterval(10)))
    }

    // MARK: N8/N9: outcomes of the system authentication

    @Test func onlyTheUsersOwnCancelIsCancelled() {
        #expect(AuthOutcome.from(.userCancel) == .cancelled)
        #expect(AuthOutcome.from(.systemCancel) == .cancelled)
        #expect(AuthOutcome.from(.appCancel) == .cancelled)
        #expect(AuthOutcome.from(.authenticationFailed) == .failed)
        #expect(AuthOutcome.from(.biometryLockout) == .failed)
        #expect(AuthOutcome.from(.notInteractive) == .failed)
        #expect(AuthOutcome.from(.passcodeNotSet) == .noPasscode)
        #expect(AuthOutcome.noPasscode.isGranted && AuthOutcome.success.isGranted)
        #expect(!AuthOutcome.cancelled.isGranted && !AuthOutcome.failed.isGranted)
    }

    // MARK: M2: security settings inside the vault

    @Test func strictDefaultsAndMissingFields() throws {
        let strict = SecuritySettings.strict
        #expect(strict.autoLockMinutes == 5 && strict.protectScreen && !strict.hideCodes && strict.clipboardClearSeconds == 30)
        let partial = try JSONDecoder().decode(SecuritySettings.self, from: Data(#"{"hideCodes":true}"#.utf8))
        #expect(partial == SecuritySettings(hideCodes: true))
        let nonsense = try JSONDecoder().decode(SecuritySettings.self, from: Data(#"{"autoLockMinutes":-3,"clipboardClearSeconds":99999,"protectScreen":"no"}"#.utf8))
        #expect(nonsense == .strict)
    }

    @Test func vaultPayloadOfVersion1_0_0WithoutTheFieldStillOpens() async throws {
        let raw = Data(##"{"accounts":[],"groups":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Firma","symbol":"building.2","colour":"#3B82F6"}]}"##.utf8)
        let decoded = try VaultData.decoded(from: raw)
        #expect(decoded.security == nil && decoded.groups.count == 1)
        // Written by this version without settings, the payload has no such key either (like a 1.0.0 file) and opens.
        let (store, url) = try makeStore()
        let p = InMemoryProtector()
        try await store.create(contents: sampleVault(), protector: p)
        await store.lock()
        let reopened = VaultStore(url: url)
        try await reopened.load()
        #expect(try await reopened.unlock(using: p).security == nil)
        let payload = try String(decoding: sampleVault().encoded(), as: UTF8.self)
        #expect(!payload.contains("security"))
    }

    @Test func securitySettingsRoundTripThroughTheVaultFile() async throws {
        let (store, url) = try makeStore()
        let p = InMemoryProtector()
        var data = sampleVault()
        try await store.create(contents: data, protector: p)
        data.security = SecuritySettings(autoLockMinutes: 15, protectScreen: false, hideCodes: true, clipboardClearSeconds: 10)
        try await store.save(data)
        await store.lock()
        let reopened = VaultStore(url: url)
        try await reopened.load()
        #expect(try await reopened.unlock(using: p).security == data.security)
        // Tampering with the file (these values are inside the authenticated ciphertext) makes it fail to open.
        var json = try header(url)
        json["ciphertext"] = flipByte(inBase64: json["ciphertext"] as! String)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let tampered = VaultStore(url: url)
        try await tampered.load()
        await #expect(throws: VaultError.corrupted) { try await tampered.unlock(using: p) }
    }

    @Test func backupsNeitherCarryNorRestoreSecuritySettings() throws {
        var data = sampleVault()
        data.security = SecuritySettings(autoLockMinutes: 0, protectScreen: false, hideCodes: false, clipboardClearSeconds: 0)
        let file = try BackupFile.encrypt(data, password: "long-enough-password", iterations: 100_000)
        let restored = try BackupFile.decrypt(file, password: "long-enough-password", acceptedIterations: 100_000...100_000)
        #expect(restored.security == nil)
        #expect(restored.accounts == data.accounts && restored.groups == data.groups)
        // A backup crafted by hand with the field in its payload does not apply it either.
        let crafted = try BackupFile.encryptRaw(try data.encoded(), password: "long-enough-password", iterations: 100_000)
        #expect(try BackupFile.decrypt(crafted, password: "long-enough-password", acceptedIterations: 100_000...100_000).security == nil)
    }

    @Test func importsKeepTheCurrentSettings() {
        var current = sampleVault()
        current.security = SecuritySettings(autoLockMinutes: 1, protectScreen: true, hideCodes: true, clipboardClearSeconds: 10)
        let merged = current.merging(accounts: [makeAccount("new", secret: "another-secret-bytes-1234")])
        #expect(merged.security == current.security)
        #expect(VaultData(accounts: [], groups: []).merging(accounts: [makeAccount()]).security == nil)   // fresh: strict defaults
    }

    @Test func backupReminderIgnoresSettings() {
        let a = makeAccount()
        var current = VaultData(accounts: [a], groups: [])
        let exported = current
        current.security = SecuritySettings(autoLockMinutes: 1)
        #expect(AppPolicy.backupCoversCurrent(exported: exported, current: current))
    }

    @Test func migrationAdoptsOnlyValuesAtLeastAsStrictAsTheDefault() {
        // Stricter or equal: adopted.
        let strict = SecuritySettings.migrated(from: .init(autoLockMinutes: 1, protectScreen: true, hideCodes: true, clipboardClearSeconds: 10))
        #expect(strict == SecuritySettings(autoLockMinutes: 1, protectScreen: true, hideCodes: true, clipboardClearSeconds: 10))
        // Weaker: replaced by the default.
        let weak = SecuritySettings.migrated(from: .init(autoLockMinutes: 0, protectScreen: false, hideCodes: false, clipboardClearSeconds: 0))
        #expect(weak == .strict)
        #expect(SecuritySettings.migrated(from: .init(autoLockMinutes: 15, clipboardClearSeconds: 60)) == .strict)
        #expect(SecuritySettings.migrated(from: .init(autoLockMinutes: 5, clipboardClearSeconds: 30)) == .strict)
        // Values that never existed are not adopted.
        #expect(SecuritySettings.migrated(from: .init(autoLockMinutes: 2, clipboardClearSeconds: 7)) == .strict)
        // Only migrate once: not if the vault already has settings, not if there is nothing old.
        #expect(VaultData.settingsToMigrate(vault: nil, legacy: .init(autoLockMinutes: 1)) == SecuritySettings(autoLockMinutes: 1))
        #expect(VaultData.settingsToMigrate(vault: .strict, legacy: .init(autoLockMinutes: 1)) == nil)
        #expect(VaultData.settingsToMigrate(vault: nil, legacy: .init()) == nil)
    }

    @Test func clipboardChangesFollowTheSameRule() {
        #expect(AppPolicy.requiresFreshAuthentication(.clipboardClearSeconds(from: 30, to: 60)))
        #expect(AppPolicy.requiresFreshAuthentication(.clipboardClearSeconds(from: 30, to: 0)))
        #expect(!AppPolicy.requiresFreshAuthentication(.clipboardClearSeconds(from: 30, to: 10)))
        #expect(!AppPolicy.requiresFreshAuthentication(.clipboardClearSeconds(from: 0, to: 30)))
    }

    // MARK: Update notice

    @Test func updateNoticeVersionIsSanitised() {
        #expect(AppPolicy.displayVersion("1.2.3") == "1.2.3")
        #expect(AppPolicy.displayVersion("2.0.0-beta.1+45") == "2.0.0-beta.1+45")
        #expect(AppPolicy.displayVersion(" 1.1.0 ") == "1.1.0")
        #expect(AppPolicy.displayVersion(nil) == nil)
        #expect(AppPolicy.displayVersion("") == nil)
        #expect(AppPolicy.displayVersion("1.2.3 <script>") == nil)
        #expect(AppPolicy.displayVersion("Klick hier: https://evil.example") == nil)
        #expect(AppPolicy.displayVersion("1.2\n3") == nil)
        #expect(AppPolicy.displayVersion("12345678901234567890") == "12345678901234567890")   // exactly 20
        #expect(AppPolicy.displayVersion("123456789012345678901") == nil)                     // 21
        #expect(AppPolicy.displayVersion("1.2.3\u{202E}") == nil)                              // bidi override
    }

    // MARK: N2: ACL

    func aclEntryCount(_ path: String) -> Int {
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else { return 0 }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var count = 0
        var entry: acl_entry_t?
        var which = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, which, &entry) == 0 {
            count += 1
            which = Int32(ACL_NEXT_ENTRY.rawValue)
        }
        return count
    }

    func chmod(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func privateFileRemovesAnExistingACL() throws {
        let file = try tempDirectory().appendingPathComponent("export.txt")
        try Data("old".utf8).write(to: file)
        try chmod(["+a", "everyone allow read", file.path])
        #expect(aclEntryCount(file.path) == 1)                       // precondition: the ACL is really there
        try PrivateFile.write(Data("secret".utf8), to: file)
        #expect(aclEntryCount(file.path) == 0)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        #expect(try Data(contentsOf: file) == Data("secret".utf8))
    }

    @Test func privateFileRemovesACLInheritedAtCreation() throws {
        let dir = try tempDirectory()
        try chmod(["+a", "everyone allow read,file_inherit", dir.path])
        // Precondition: a plain file in this folder inherits the entry (otherwise this test would prove nothing).
        let plain = dir.appendingPathComponent("plain.txt")
        try Data("x".utf8).write(to: plain)
        let inherited = aclEntryCount(plain.path) > 0
        let file = dir.appendingPathComponent("export.txt")
        try PrivateFile.write(Data("secret".utf8), to: file)
        #expect(aclEntryCount(file.path) == 0)
        #expect(inherited, "the folder's file_inherit entry should apply to a normally created file")
    }

    // MARK: N3: counters

    @Test func andOTPCountersMustBeExactNonNegativeIntegers() throws {
        func entry(_ counter: String) -> String {
            #"[{"secret":"\#(ImportTests.s1)","label":"c","type":"HOTP","counter":\#(counter)}]"#
        }
        func read(_ counter: String) throws -> ImportResult {
            guard case .accounts(let r) = try ImportDetector.detect(Data(entry(counter).utf8), now: now) else { throw ImportError.unrecognizedFormat }
            return r
        }
        #expect(try read("5").accounts.first?.counter == 5)
        #expect(try read("0").accounts.first?.counter == 0)
        #expect(try read("18446744073709551615").accounts.first?.counter == UInt64.max)
        #expect(try read("9223372036854775808").accounts.first?.counter == UInt64(Int64.max) + 1)
        #expect(try read("5.0").accounts.first?.counter == 5)
        for bad in ["5.7", "1e30", "-1", "18446744073709551616", "1e19", "\"7\"", "true", "null"] {
            let r = try read(bad)
            #expect(r.accounts.isEmpty && r.skipped.count == 1 && r.skipped[0].reason == .invalidParameter("counter"), "counter \(bad)")
        }
    }

    @Test func aegisCountersMustBeExactNonNegativeIntegers() throws {
        func aegis(_ counter: String) -> String {
            #"{"version":1,"header":{"slots":null,"params":null},"db":{"version":3,"entries":[{"type":"hotp","name":"h","issuer":"","info":{"secret":"\#(ImportTests.s1)","algo":"SHA1","digits":6,"counter":\#(counter)}}],"groups":[]}}"#
        }
        func read(_ counter: String) throws -> ImportResult {
            guard case .accounts(let r) = try ImportDetector.detect(Data(aegis(counter).utf8), now: now) else { throw ImportError.unrecognizedFormat }
            return r
        }
        #expect(try read("12").accounts.first?.counter == 12)
        #expect(try read("18446744073709551615").accounts.first?.counter == UInt64.max)
        for bad in ["5.7", "1e30", "-3"] {
            let r = try read(bad)
            #expect(r.accounts.isEmpty && r.skipped.count == 1, "counter \(bad)")
        }
    }

    // MARK: N4: CSV detection

    func detect(_ text: String) throws -> ImportDetection { try ImportDetector.detect(Data(text.utf8), now: now) }
    func result(_ text: String) throws -> ImportResult {
        guard case .accounts(let r) = try detect(text) else { throw ImportError.unrecognizedFormat }
        return r
    }

    @Test func blankLinesBeforeTheCSVHeaderAreSkipped() throws {
        let r = try result("\n\r\n   \n\nname,totp\nA,\(ImportTests.s1)\n")
        #expect(r.format == .genericCSV && r.accounts.count == 1 && r.accounts[0].issuer == "A")
        let apple = try result("\n\nTitle,URL,Username,Password,Notes,OTPAuth\nEx,,al,pw,,otpauth://totp?secret=\(ImportTests.s1)\n")
        #expect(apple.format == .applePasswordsCSV && apple.accounts.count == 1)
    }

    @Test func rowsWithContentOnlyInADiscardedColumnAreRowsWithoutCode() throws {
        let rows = try CSV.parse("a,b,c\nonly-in-b-pw\n,pw,\n  \n,,\n", keep: [2])   // 3 columns, keep column c
        #expect(rows.count == 4)                                                       // header, "only-in-b-pw", ",pw,", ",,"
        let text = "name,password,totp\nA,pw1,\nB,pw2,\n,,\n"
        let r = try result(text)
        #expect(r.accounts.isEmpty && r.rowsWithoutCode == 3)
        // A row whose only content is the (discarded) password column counts too.
        let onlyPassword = try result("name,password,totp\n,secret,\n")
        #expect(onlyPassword.rowsWithoutCode == 1)
    }

    @Test func discardedColumnRowsCountTowardTheRowLimit() {
        let body = String(repeating: ",x,\n", count: Limits.maxCSVRows + 1)
        #expect(throws: ImportError.tooManyEntries) { try CSV.parse("a,b,c\n" + body, keep: [0]) }
    }

    @Test func otpauthLineListWithAHeaderLikeFirstLineIsStillALineList() throws {
        let text = "# comment, otp\notpauth://totp/Example:alice?secret=\(ImportTests.s1)&issuer=Example\notpauth://totp/B:bob?secret=\(ImportTests.s2)\n"
        let r = try result(text)
        #expect(r.format == .otpauthLines && r.accounts.count == 2)
        let twofa = try result("my 2fa, backup\notpauth://totp/X:x?secret=\(ImportTests.s1)\n")
        #expect(twofa.format == .otpauthLines && twofa.accounts.count == 1)
    }

    @Test func aCSVWithoutUsableCodesHasNothingToReview() throws {
        let headerOnly = try result("name,totp\n")
        #expect(headerOnly.hasNothingToReview && headerOnly.rowsWithoutCode == 0)
        let noCodes = try result("name,totp\nA,\nB,\n")
        #expect(noCodes.hasNothingToReview && noCodes.rowsWithoutCode == 2)
        let withCode = try result("name,totp\nA,\(ImportTests.s1)\n")
        #expect(!withCode.hasNothingToReview)
        let onlyBroken = try result("name,totp\nA,!!!\n")
        #expect(!onlyBroken.hasNothingToReview)                       // listed as unusable: the review sheet explains
    }

    // MARK: N5: Apple Passwords round trip

    @Test func applePasswordsCSVRoundTripKeepsIssuerAndNameStable() throws {
        var noIssuer = makeAccount("solo-name", issuer: "", secret: "secret-without-issuer-1")
        noIssuer.sortIndex = 0
        var withIssuer = makeAccount("alice", issuer: "Example", secret: "secret-with-issuer-2")
        withIssuer.sortIndex = 1
        var noted = makeAccount("bob", issuer: "Mail", secret: "secret-with-note-333")
        noted.note = "recovery notes"
        noted.sortIndex = 2
        let out = AccountExporter.applePasswordsCSV([noIssuer, withIssuer, noted])
        let r = try result(String(decoding: out.data, as: UTF8.self))
        #expect(r.format == .applePasswordsCSV && r.accounts.count == 3)
        #expect(r.accounts[0].issuer == "" && r.accounts[0].name == "solo-name")
        #expect(r.accounts[1].issuer == "Example" && r.accounts[1].name == "alice")
        #expect(r.accounts[2].issuer == "Mail" && r.accounts[2].name == "bob")
        // Second round: still stable.
        let again = try result(String(decoding: AccountExporter.applePasswordsCSV(r.accounts).data, as: UTF8.self))
        #expect(again.accounts.map(\.issuer) == r.accounts.map(\.issuer) && again.accounts.map(\.name) == r.accounts.map(\.name))
    }

    @Test func applePasswordsNotesAreNeverImportedAndOnlyExportedWhenPresent() throws {
        let text = "Title,URL,Username,Password,Notes,OTPAuth\nEx,,al,pw,\"recovery code 1234-5678\",otpauth://totp?secret=\(ImportTests.s1)\n"
        let r = try result(text)
        #expect(r.accounts.count == 1 && r.accounts[0].note.isEmpty)
        var dumped = ""
        dump(r, to: &dumped)
        #expect(!dumped.contains("1234-5678"))
        // Export: empty note = empty cell; a note is written only if the account has one.
        let plain = AccountExporter.applePasswordsCSV([makeAccount("a", issuer: "I")])
        #expect(try CSV.parse(String(decoding: plain.data, as: UTF8.self))[1][4] == "")
    }
}
