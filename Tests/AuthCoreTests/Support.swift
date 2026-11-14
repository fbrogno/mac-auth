import Foundation
@testable import AuthCore

func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("macauth-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeAccount(_ name: String = "alice@example.com", issuer: String = "Example", secret: String = "12345678901234567890",
                 algorithm: OTPAlgorithm = .sha1, digits: Int = 6, period: Int = 30, kind: OTPKind = .totp,
                 counter: UInt64 = 0) -> Account {
    Account(issuer: issuer, name: name, secret: Data(secret.utf8), algorithm: algorithm, digits: digits, period: period,
            kind: kind, counter: counter, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
}

func sampleVault() -> VaultData {
    let groups = AccountGroup.makeDefaults()
    return VaultData(accounts: [
        makeAccount(),
        makeAccount("bob", issuer: "Büro Ärger", secret: "abcdefghijklmnopqrstuvwxyz012345", algorithm: .sha256, digits: 8, kind: .hotp, counter: 7),
    ], groups: groups)
}

func flipByte(inBase64 text: String) -> String {
    var data = Data(base64Encoded: text)!
    data[data.count / 2] ^= 0x01
    return data.base64EncodedString()
}
