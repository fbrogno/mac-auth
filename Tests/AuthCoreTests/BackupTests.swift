import Foundation
import Testing
@testable import AuthCore

struct BackupTests {
    static let password = "correct horse battery"
    static let fast = 1000...10_000_000   // test-only lower bound

    func fastFile(_ data: VaultData = sampleVault(), password: String = password) throws -> Data {
        try BackupFile.encrypt(data, password: password, iterations: 1000)
    }

    func json(_ file: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: file) as! [String: Any]
    }

    @Test func roundTripWithDefaultIterations() throws {
        let data = sampleVault()
        let file = try BackupFile.encrypt(data, password: Self.password)
        let header = try json(file)
        #expect(header["format"] as? String == "macauth-backup")
        #expect(header["version"] as? Int == 1)
        #expect(header["cipher"] as? String == "aes-256-gcm")
        let kdf = header["kdf"] as! [String: Any]
        #expect(kdf["name"] as? String == "pbkdf2-hmac-sha256")
        #expect(kdf["iterations"] as? Int == 600_000)
        #expect(!String(decoding: file, as: UTF8.self).contains("alice"))
        #expect(try BackupFile.decrypt(file, password: Self.password) == data)
    }

    @Test func wrongPassword() throws {
        let file = try BackupFile.encrypt(sampleVault(), password: Self.password)
        #expect(throws: BackupError.wrongPasswordOrCorrupt) { try BackupFile.decrypt(file, password: "wrong password!") }
        #expect(throws: BackupError.wrongPasswordOrCorrupt) { try BackupFile.decrypt(file, password: "") }
    }

    @Test func tooShortPassword() {
        #expect(throws: BackupError.passwordTooShort(minimum: 10)) { try BackupFile.encrypt(sampleVault(), password: "123456789") }
        #expect(throws: Never.self) { try BackupFile.encrypt(VaultData(accounts: []), password: "1234567890", iterations: 1000) }
    }

    @Test func unicodePasswordIsNormalised() throws {
        let composed = "Pässwörter-123"                       // ä ö as single scalars
        let decomposed = "Pa\u{0308}sswo\u{0308}rter-123"     // a + combining diaeresis
        #expect(Array(composed.utf8) != Array(decomposed.utf8))   // different bytes, same text
        let data = sampleVault()
        let file = try fastFile(data, password: composed)
        #expect(try BackupFile.decrypt(file, password: decomposed, acceptedIterations: Self.fast) == data)
    }

    @Test func tamperedFileIsRejected() throws {
        let file = try fastFile()
        func tampered(_ edit: (inout [String: Any]) -> Void) throws -> Data {
            var h = try json(file)
            edit(&h)
            return try JSONSerialization.data(withJSONObject: h)
        }
        let cases: [(String, Data)] = [
            ("ciphertext", try tampered { $0["ciphertext"] = flipByte(inBase64: $0["ciphertext"] as! String) }),
            ("tag", try tampered { $0["tag"] = flipByte(inBase64: $0["tag"] as! String) }),
            ("nonce", try tampered { $0["nonce"] = flipByte(inBase64: $0["nonce"] as! String) }),
            ("salt", try tampered { var k = $0["kdf"] as! [String: Any]; k["salt"] = flipByte(inBase64: k["salt"] as! String); $0["kdf"] = k }),
            ("iterations", try tampered { var k = $0["kdf"] as! [String: Any]; k["iterations"] = 1001; $0["kdf"] = k }),
        ]
        for (name, data) in cases {
            #expect(throws: BackupError.wrongPasswordOrCorrupt, "tampered \(name)") {
                try BackupFile.decrypt(data, password: Self.password, acceptedIterations: Self.fast)
            }
        }
        // Truncated ciphertext (not a multiple problem for GCM, but the tag no longer matches).
        let truncated = try tampered {
            var c = Data(base64Encoded: $0["ciphertext"] as! String)!
            c.removeLast()
            $0["ciphertext"] = c.base64EncodedString()
        }
        #expect(throws: BackupError.wrongPasswordOrCorrupt) { try BackupFile.decrypt(truncated, password: Self.password, acceptedIterations: Self.fast) }
    }

    @Test func rejectsForeignOrUnsupportedFiles() throws {
        #expect(throws: BackupError.notABackup) { try BackupFile.decrypt(Data("hello".utf8), password: Self.password) }
        #expect(throws: BackupError.notABackup) { try BackupFile.decrypt(Data(), password: Self.password) }
        #expect(throws: BackupError.notABackup) { try BackupFile.decrypt(Data("{\"format\":\"other\"}".utf8), password: Self.password) }
        let file = try fastFile()
        var h = try json(file)
        h["version"] = 2
        #expect(throws: BackupError.unsupportedVersion(2)) {
            try BackupFile.decrypt(try JSONSerialization.data(withJSONObject: h), password: Self.password, acceptedIterations: Self.fast)
        }
        h["version"] = 1
        h["cipher"] = "aes-128-cbc"
        #expect(throws: BackupError.unsupportedParameters) {
            try BackupFile.decrypt(try JSONSerialization.data(withJSONObject: h), password: Self.password, acceptedIterations: Self.fast)
        }
    }

    @Test func iterationCountIsBoundedOutsideTests() throws {
        // A file written with a tiny count is refused by the public API (even with the right password).
        let weak = try fastFile()
        #expect(throws: BackupError.unsupportedParameters) { try BackupFile.decrypt(weak, password: Self.password) }
        // An absurdly large count is refused before any key derivation starts.
        var h = try json(weak)
        var kdf = h["kdf"] as! [String: Any]
        kdf["iterations"] = 2_000_000_000
        h["kdf"] = kdf
        let hostile = try JSONSerialization.data(withJSONObject: h)
        let start = Date()
        #expect(throws: BackupError.unsupportedParameters) { try BackupFile.decrypt(hostile, password: Self.password) }
        #expect(Date().timeIntervalSince(start) < 2)
        kdf["iterations"] = 0
        h["kdf"] = kdf
        #expect(throws: BackupError.unsupportedParameters) {
            try BackupFile.decrypt(try JSONSerialization.data(withJSONObject: h), password: Self.password)
        }
        #expect(BackupFile.acceptedIterations.contains(BackupFile.defaultIterations))
    }

    @Test func oversizedFileIsRejected() {
        #expect(throws: BackupError.notABackup) { try BackupFile.decrypt(Data(count: Limits.maxFileBytes + 1), password: Self.password) }
    }
}
