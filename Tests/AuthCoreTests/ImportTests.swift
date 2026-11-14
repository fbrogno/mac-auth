import Foundation
import Testing
@testable import AuthCore

struct ImportTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    // Invented secrets only.
    static let s1 = "JBSWY3DPEHPK3PXP"                       // 10 bytes
    static let s2 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"       // "12345678901234567890" x2 (20 bytes)

    func detect(_ text: String) throws -> ImportDetection { try ImportDetector.detect(Data(text.utf8), now: now) }

    func accounts(_ d: ImportDetection) -> ImportResult? {
        if case .accounts(let r) = d { return r }
        return nil
    }

    // MARK: otpauth lines

    @Test func otpauthLinesTolerateBOMCRLFAndBlankLines() throws {
        let text = "\u{FEFF}otpauth://totp/Ente:me@example.com?secret=\(Self.s1)&issuer=Ente\r\n\r\n" +
            "  otpauth://hotp/Mail:bob?secret=\(Self.s2)&counter=3&digits=8&algorithm=SHA256  \r\n" +
            "otpauth://totp/Bad?secret=!!!\r\n# comment\r\notpauth://steam/x?secret=\(Self.s1)\r\n"
        let r = try #require(accounts(try detect(text)))
        #expect(r.format == .otpauthLines)
        #expect(r.accounts.count == 2)
        #expect(r.accounts[0].issuer == "Ente" && r.accounts[0].name == "me@example.com" && r.accounts[0].sortIndex == 0)
        #expect(r.accounts[1].kind == .hotp && r.accounts[1].counter == 3 && r.accounts[1].digits == 8 && r.accounts[1].sortIndex == 1)
        #expect(r.skipped == [SkippedEntry(label: "Zeile 4", reason: .invalidSecret),
                              SkippedEntry(label: "Zeile 5", reason: .notAnOTPAuthLine),
                              SkippedEntry(label: "Zeile 6", reason: .unsupportedType("steam"))])
        // Skipped entries never contain the secret or the link.
        for s in r.skipped { #expect(!s.label.contains("secret") && !s.reason.description.contains(Self.s1)) }
    }

    @Test func detectsGoogleMigrationLinks() throws {
        let uri = "otpauth-migration://offline?data=" + MigrationTests.fixtureC
        let d = try detect(uri + "\n" + uri + "\n")
        guard case .googleMigration(let uris) = d else { Issue.record("expected migration"); return }
        #expect(uris == [uri, uri])
    }

    @Test func detectsOwnBackup() throws {
        let file = try BackupFile.encrypt(sampleVault(), password: "1234567890", iterations: 1000)
        guard case .macauthBackup = try ImportDetector.detect(file) else { Issue.record("expected backup"); return }
    }

    // MARK: Aegis

    static let aegis = """
    {"version":1,"header":{"slots":null,"params":null},"db":{"version":3,"entries":[
     {"type":"totp","uuid":"01234567-89ab-4cde-8f01-23456789abcd","name":"alice@example.com","issuer":"Example","note":"Notiz","favorite":true,
      "icon":null,"info":{"secret":"\(s1)","algo":"SHA1","digits":6,"period":30},"groups":["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]},
     {"type":"hotp","uuid":"11111111-1111-4111-8111-111111111111","name":"bob","issuer":"","note":"","favorite":false,
      "info":{"secret":"\(s2)","algo":"SHA512","digits":8,"counter":42},"groups":[]},
     {"type":"steam","uuid":"22222222-2222-4222-8222-222222222222","name":"gamer","issuer":"Steam","info":{"secret":"\(s1)","algo":"SHA1","digits":5,"period":30}},
     {"type":"motp","name":"old","issuer":"Legacy","info":{"secret":"\(s1)","algo":"MD5","digits":6,"period":10,"pin":"1234"}},
     {"type":"totp","name":"md5","issuer":"X","info":{"secret":"\(s1)","algo":"MD5","digits":6,"period":30}},
     {"type":"totp","name":"badsecret","issuer":"Y","info":{"secret":"1!","algo":"SHA1","digits":6,"period":30}}
    ],"groups":[{"uuid":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","name":"Arbeit"},{"uuid":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","name":"Privat"}]}}
    """

    @Test func readsUnencryptedAegis() throws {
        let r = try #require(accounts(try detect(Self.aegis)))
        #expect(r.format == .aegis)
        #expect(r.accounts.count == 2)
        let a = r.accounts[0]
        #expect(a.issuer == "Example" && a.name == "alice@example.com" && a.pinned && a.note == "Notiz")
        #expect(a.secret.count == 10 && a.algorithm == .sha1 && a.digits == 6 && a.period == 30 && a.kind == .totp)
        #expect(r.groups.map(\.name) == ["Arbeit", "Privat"])
        #expect(a.groupID == r.groups[0].id)
        let b = r.accounts[1]
        #expect(b.kind == .hotp && b.counter == 42 && b.algorithm == .sha512 && b.digits == 8 && b.groupID == nil && b.name == "bob")
        #expect(r.skipped.map(\.label) == ["Steam (gamer)", "Legacy (old)", "X (md5)", "Y (badsecret)"])
        #expect(r.skipped.map(\.reason) == [.unsupportedType("steam"), .unsupportedType("motp"), .unsupportedAlgorithm("MD5"), .invalidSecret])
    }

    @Test func rejectsEncryptedAegis() throws {
        let enc = """
        {"version":1,"header":{"slots":[{"type":1,"uuid":"01234567-89ab-4cde-8f01-23456789abcd","key":"00ff","key_params":{"nonce":"00","tag":"00"},
        "n":32768,"r":8,"p":1,"salt":"00ff"}],"params":{"nonce":"00ff","tag":"00ff"}},"db":"AAAA"}
        """
        #expect(throws: ImportError.encryptedFile(.aegis)) { try detect(enc) }
        #expect(throws: ImportError.unsupportedVersion("Aegis 2")) { try detect(#"{"version":2,"header":{"slots":null,"params":null},"db":{"entries":[]}}"#) }
        #expect(ImportError.encryptedFile(.aegis).errorDescription?.contains("unverschlüsselt exportieren") == true)
    }

    // MARK: 2FAS

    static let twofas = """
    {"services":[
     {"name":"Second","secret":"\(s2)","updatedAt":1700000000000,"serviceTypeID":null,"otp":{"account":"bob","issuer":"Second Inc","digits":8,"period":60,"algorithm":"SHA256","counter":0,"tokenType":"TOTP","source":"manual"},
      "order":{"position":1},"badge":null,"icon":{"selected":"Label","label":{"text":"SE","backgroundColor":"Red"}},"groupId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"},
     {"name":"GitHub","secret":"\(s1)","updatedAt":1600000000000,"otp":{"account":"alice","issuer":"","tokenType":"totp"},
      "order":{"position":0},"groupId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"},
     {"name":"Counter","secret":"\(s1)","otp":{"account":"c","algorithm":"SHA1","digits":6,"counter":9,"tokenType":"HOTP"},"order":{"position":2}},
     {"name":"Steam","secret":"\(s1)","otp":{"tokenType":"STEAM"},"order":{"position":3}},
     {"name":"Weird","secret":"\(s1)","otp":{"algorithm":"SHA224"},"order":{"position":4}}
    ],"groups":[{"id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","name":" privat ","isExpanded":true}],
    "updatedAt":1700000000000,"schemaVersion":4,"appVersionCode":500000,"appVersionName":"5.0.0","appOrigin":"android","reference":null,"servicesEncrypted":null}
    """

    @Test func readsUnencrypted2FAS() throws {
        let r = try #require(accounts(try detect(Self.twofas)))
        #expect(r.format == .twoFAS)
        #expect(r.accounts.map(\.issuer) == ["GitHub", "Second Inc", "Counter"])    // by order.position; issuer falls back to name
        let gh = r.accounts[0]
        #expect(gh.name == "alice" && gh.digits == 6 && gh.period == 30 && gh.algorithm == .sha1 && gh.kind == .totp)
        #expect(gh.createdAt == Date(timeIntervalSince1970: 1_600_000_000))
        let second = r.accounts[1]
        #expect(second.name == "bob" && second.digits == 8 && second.period == 60 && second.algorithm == .sha256)
        #expect(r.groups.map(\.name) == ["privat"] && second.groupID == r.groups[0].id && gh.groupID == r.groups[0].id)
        #expect(r.accounts[2].kind == .hotp && r.accounts[2].counter == 9 && r.accounts[2].groupID == nil)
        #expect(r.skipped.map(\.reason) == [.unsupportedType("STEAM"), .unsupportedAlgorithm("SHA224")])
        #expect(r.accounts.map(\.sortIndex) == [0, 1, 2])
    }

    @Test func rejectsEncrypted2FAS() throws {
        let enc = #"{"services":[],"groups":[],"updatedAt":1,"schemaVersion":4,"appVersionCode":1,"appVersionName":"5","appOrigin":"ios","servicesEncrypted":"QUJD:REVG:R0hJ","reference":"QUJDREVG:REVG:R0hJ"}"#
        #expect(throws: ImportError.encryptedFile(.twoFAS)) { try detect(enc) }
        #expect(throws: ImportError.encryptedFile(.twoFAS)) { try detect(#"{"servicesEncrypted":"AAAA","reference":"BBBB","services":[]}"#) }
        #expect(throws: ImportError.unsupportedVersion("2FAS 9")) { try detect(#"{"services":[],"schemaVersion":9}"#) }
    }

    // MARK: Errors and limits

    @Test func rejectsUnknownAndHostileInput() throws {
        #expect(throws: ImportError.emptyFile) { try ImportDetector.detect(Data()) }
        #expect(throws: ImportError.emptyFile) { try detect(" \n\r\n ") }
        #expect(throws: ImportError.unrecognizedFormat) { try detect("hello world") }
        #expect(throws: ImportError.unrecognizedFormat) { try detect("{\"other\":1}") }
        #expect(throws: ImportError.unrecognizedFormat) { try detect("{not json") }
        #expect(throws: ImportError.unrecognizedFormat) { try ImportDetector.detect(Data([0xFF, 0xFE, 0x00, 0x80])) }
        #expect(throws: ImportError.tooLarge) { try ImportDetector.detect(Data(count: Limits.maxFileBytes + 1)) }
        let many = String(repeating: "otpauth://totp/x?secret=\(Self.s1)\n", count: ImportDetector.maxEntries + 1)
        #expect(throws: ImportError.tooManyEntries) { try detect(many) }
        let deep = String(repeating: "[", count: 100_000)
        #expect(throws: ImportError.unrecognizedFormat) { try detect("{\"services\":" + deep) }
        let tooManyServices = "{\"services\":[" + Array(repeating: "{}", count: ImportDetector.maxEntries + 1).joined(separator: ",") + "]}"
        #expect(throws: ImportError.tooManyEntries) { try detect(tooManyServices) }
    }

    @Test func malformedEntriesAreSkippedNotFatal() throws {
        let json = #"{"services":[1,"x",{"name":5,"secret":7,"otp":3},{"name":"A","secret":"\#(Self.s1)","otp":{"digits":"six"}},{"name":"B","secret":"\#(Self.s1)","otp":{"digits":true}}]}"#
        let r = try #require(accounts(try detect(json)))
        #expect(r.accounts.isEmpty)
        #expect(r.skipped.count == 3)
        let aegis = #"{"header":{},"db":{"entries":[null,{"type":"totp"},{"type":"totp","info":{"secret":"\#(Self.s1)","algo":"SHA1","digits":6.5,"period":30}}]}}"#
        let a = try #require(accounts(try detect(aegis)))
        #expect(a.accounts.isEmpty && a.skipped.count == 2)
    }

    @Test func fuzzNeverCrashes() {
        var state: UInt64 = 0xDEAD_BEEF_1234_5678
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
        let seeds = [Self.aegis, Self.twofas, "otpauth://totp/x?secret=\(Self.s1)\notpauth-migration://offline?data=AAAA"].map { [UInt8]($0.utf8) }
        for _ in 0..<3000 {
            var bytes = seeds[Int(next()) % seeds.count]
            for _ in 0..<(1 + Int(next()) % 8) { bytes[Int(next()) % bytes.count] = next() }
            if next() % 3 == 0 { bytes.removeLast(Int(next()) % bytes.count) }
            _ = try? ImportDetector.detect(Data(bytes), now: now)
        }
        for _ in 0..<500 { _ = try? ImportDetector.detect(Data((0..<Int(next())).map { _ in next() })) }
    }
}

struct MergeAndExportTests {
    @Test func mergeAssignsNewIDsMergesGroupsAndAppendsSortIndex() {
        let firma = AccountGroup(name: "Firma")
        var existingA = makeAccount("a"); existingA.sortIndex = 4; existingA.groupID = firma.id
        let existing = VaultData(accounts: [existingA], groups: [firma])

        let importedGroups = [AccountGroup(name: "  FIRMA "), AccountGroup(name: "Neu"), AccountGroup(name: "neu")]
        var i1 = makeAccount("i1", secret: "s1-padpadpadpadpad"); i1.groupID = importedGroups[0].id
        var i2 = makeAccount("i2", secret: "s2-padpadpadpadpad"); i2.groupID = importedGroups[2].id
        var i3 = makeAccount("i3", secret: "s3-padpadpadpadpad"); i3.groupID = UUID()          // unknown group
        i3.id = existingA.id                                                                    // UUID collision
        var i4 = makeAccount("i4", secret: "s4-padpadpadpadpad"); i4.id = i1.id                 // collision within the import

        let merged = existing.merging(accounts: [i1, i2, i3, i4], groups: importedGroups)
        #expect(merged.accounts.count == 5)
        #expect(Set(merged.accounts.map(\.id)).count == 5)
        #expect(merged.accounts[0] == existingA)                                                // existing untouched
        #expect(merged.groups.map(\.name) == ["Firma", "Neu"])
        #expect(merged.accounts[1].groupID == firma.id)
        #expect(merged.accounts[2].groupID == merged.groups[1].id)
        #expect(merged.accounts[3].groupID == nil)
        #expect(merged.accounts.dropFirst().map(\.sortIndex) == [5, 6, 7, 8])
        #expect(merged.accounts[3].id != existingA.id)
        // The input is a value; nothing else changed.
        #expect(existing.accounts.count == 1 && existing.groups.count == 1)
        #expect(VaultData(accounts: [], groups: []).merging(accounts: [makeAccount()]).accounts[0].sortIndex == 0)
    }

    @Test func exportRefusesWhatGoogleCannotRepresent() throws {
        let label = "Example (alice@example.com)"
        #expect(throws: MigrationError.unsupportedForExport(label)) { try MigrationCodec.uris(for: [makeAccount(period: 45)]) }
        #expect(throws: MigrationError.unsupportedForExport(label)) { try MigrationCodec.uris(for: [makeAccount(digits: 7)]) }
        #expect(throws: MigrationError.unsupportedForExport(label)) { try MigrationCodec.uris(for: [makeAccount(kind: .hotp, counter: UInt64(Int64.max) + 1)]) }
        #expect(throws: MigrationError.unsupportedForExport(label)) { try MigrationCodec.uris(for: [makeAccount(secret: String(repeating: "x", count: 300))]) }
        #expect(throws: Never.self) { try MigrationCodec.uris(for: [makeAccount(period: 30), makeAccount(period: 45, kind: .hotp), makeAccount(algorithm: .sha512, digits: 8)]) }
    }
}
