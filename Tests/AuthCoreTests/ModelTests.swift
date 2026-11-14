import Foundation
import Testing
@testable import AuthCore

struct ModelTests {
    @Test func duplicateDetection() {
        let a = makeAccount()
        #expect(a.isDuplicate(of: makeAccount("other name", issuer: "Other")))            // same secret + parameters
        #expect(!a.isDuplicate(of: makeAccount(secret: "different-secret-xxxx")))
        #expect(!a.isDuplicate(of: makeAccount(algorithm: .sha256)))
        #expect(!a.isDuplicate(of: makeAccount(digits: 8)))
        #expect(!a.isDuplicate(of: makeAccount(period: 60)))
        #expect(!a.isDuplicate(of: makeAccount(kind: .hotp)))
        #expect(makeAccount(period: 30, kind: .hotp).isDuplicate(of: makeAccount(period: 60, kind: .hotp)))   // period ignored for HOTP

        let existing = [makeAccount()]
        let flags = Account.duplicateFlags(candidates: [makeAccount("x"), makeAccount(secret: "new-secret-0123456789"), makeAccount(secret: "new-secret-0123456789")],
                                           existing: existing)
        #expect(flags == [true, false, true])
    }

    @Test func secretNeverAppearsInDescriptions() {
        let account = makeAccount(secret: "SuperGeheim1234567890")
        let secretText = "SuperGeheim1234567890"
        let secretBase64 = Data(secretText.utf8).base64EncodedString()
        let secretBase32 = Base32.encode(Data(secretText.utf8))
        var dumped = ""
        dump(account, to: &dumped)
        let outputs = [account.description, account.debugDescription, "\(account)", String(describing: account),
                       String(reflecting: account), dumped, "\([account])", "\(VaultData(accounts: [account]).accounts)"]
        for out in outputs {
            #expect(!out.contains(secretText))
            #expect(!out.contains(secretBase64))
            #expect(!out.contains(secretBase32))
            #expect(!out.contains("5375706572")) // hex of "Super"
        }
        #expect(account.description.contains("redacted"))
    }

    @Test func errorsContainNoSecrets() {
        let secretText = "SuperGeheim1234567890"
        let account = makeAccount(secret: secretText, digits: 7)
        do {
            _ = try MigrationCodec.uris(for: [account])
            Issue.record("expected an error")
        } catch {
            #expect(!error.localizedDescription.contains(secretText))
            #expect(error.localizedDescription.contains("Example"))
        }
    }

    @Test func codableRoundTripKeepsEverything() throws {
        var data = sampleVault()
        data.accounts[0].groupID = data.groups[0].id
        data.accounts[0].pinned = true
        data.accounts[0].lastUsedAt = Date(timeIntervalSince1970: 1_700_000_500)
        data.accounts[0].note = "Notiz mit Ümlaut"
        let decoded = try VaultData.decoded(from: data.encoded())
        #expect(decoded == data)
    }

    @Test func defaultGroups() {
        let groups = AccountGroup.makeDefaults()
        #expect(groups.map(\.name) == ["Firma", "Privat"])
        #expect(Set(groups.map(\.id)).count == 2)
    }

    @Test func validation() throws {
        try makeAccount().validate()
        #expect(throws: OTPError.emptySecret) { try Account(name: "x", secret: Data()).validate() }
        #expect(throws: OTPError.invalidDigits(9)) { try makeAccount(digits: 9).validate() }
        #expect(throws: OTPError.invalidPeriod(5)) { try makeAccount(period: 5).validate() }
    }
}
