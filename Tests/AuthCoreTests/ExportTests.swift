import Foundation
import Testing
@testable import AuthCore

struct ExportTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func accounts() -> [Account] {
        var list: [Account] = []
        var idx = 0
        for algorithm in OTPAlgorithm.allCases {
            for digits in 6...8 {
                for period in [15, 30, 120] {
                    list.append(makeAccount("user\(idx)@example.com", issuer: "Iss\(idx)", secret: "secret-bytes-\(idx)-abcdefgh", algorithm: algorithm, digits: digits, period: period))
                    idx += 1
                }
            }
            list.append(makeAccount("hotp\(idx)", issuer: "H\(idx)", secret: "hotp-secret-\(idx)-xyz12345", algorithm: algorithm, digits: 7, kind: .hotp, counter: UInt64(idx) * 1_000_000_007))
            idx += 1
        }
        for i in list.indices { list[i].sortIndex = i }
        return list
    }

    func sameParameters(_ a: [Account], _ b: [Account]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y in
            x.isDuplicate(of: y) && x.issuer == y.issuer && x.name == y.name && (x.kind != .hotp || x.counter == y.counter)
        }
    }

    func imported(_ data: Data) throws -> ImportResult {
        guard case .accounts(let r) = try ImportDetector.detect(data, now: now) else { throw ImportError.unrecognizedFormat }
        return r
    }

    @Test func otpauthListRoundTrips() throws {
        let src = accounts()
        let out = AccountExporter.otpauthList(src)
        #expect(out.skipped.isEmpty && out.exportedCount == src.count)
        let text = String(decoding: out.data, as: UTF8.self)
        #expect(text.hasSuffix("\n") && !text.hasSuffix("\n\n") && text.split(separator: "\n").count == src.count)
        let r = try imported(out.data)
        #expect(r.format == .otpauthLines && r.skipped.isEmpty)
        #expect(sameParameters(src, r.accounts))
    }

    @Test func otpauthListKeepsColonInNameWithoutIssuer() throws {
        let src = [makeAccount("a:b", issuer: ""), makeAccount("c d/é", issuer: "Is:su er")]
        let r = try imported(AccountExporter.otpauthList(src).data)
        #expect(r.accounts.map(\.name) == ["a:b", "c d/é"] && r.accounts.map(\.issuer) == ["", "Is:su er"])
    }

    @Test func aegisExportRoundTripsThroughOwnImporter() throws {
        var src = accounts()
        let groups = [AccountGroup(name: "Arbeit"), AccountGroup(name: "Privat")]
        src[0].groupID = groups[1].id
        src[1].pinned = true
        src[1].note = "Notiz \"mit\" Anführungszeichen"
        let out = try AccountExporter.aegisJSON(src, groups: groups)
        #expect(out.skipped.isEmpty && out.exportedCount == src.count)
        let r = try imported(out.data)
        #expect(r.format == .aegis && r.skipped.isEmpty)
        #expect(sameParameters(src, r.accounts))
        #expect(r.groups.map(\.name) == ["Arbeit", "Privat"])
        #expect(r.accounts[0].groupID == r.groups[1].id && r.accounts[1].groupID == nil)
        #expect(r.accounts[1].pinned && r.accounts[1].note == src[1].note)
        // Structure per docs/vault.md: unencrypted marker and db version.
        let root = try #require(JSONSerialization.jsonObject(with: out.data) as? [String: Any])
        let header = try #require(root["header"] as? [String: Any])
        #expect(header["slots"] is NSNull && header["params"] is NSNull && root["version"] as? Int == 1)
        #expect((root["db"] as? [String: Any])?["version"] as? Int == 3)
    }

    @Test func appleCSVWritesTOTPAndReportsHOTP() throws {
        let src = accounts()
        let out = AccountExporter.applePasswordsCSV(src)
        let hotp = src.filter { $0.kind == .hotp }
        #expect(out.skipped.map(\.label) == hotp.map(\.displayLabel))
        #expect(out.skipped.allSatisfy { $0.reason == .hotpNotSupported })
        #expect(out.exportedCount == src.count - hotp.count)
        let text = String(decoding: out.data, as: UTF8.self)
        #expect(text.hasPrefix("Title,URL,Username,Password,Notes,OTPAuth\n") && text.hasSuffix("\n"))
        let r = try imported(out.data)
        #expect(r.format == .applePasswordsCSV && r.skipped.isEmpty && r.rowsWithoutCode == 0)
        #expect(sameParameters(src.filter { $0.kind == .totp }, r.accounts))
    }

    @Test func appleCSVQuotesAndKeepsUsernamesUnchanged() throws {
        // No formula-injection prefix: the consumer is the Passwords app, so `+49…`, `-name`, `=x`, `@bob` must survive.
        var a = makeAccount("=HYPERLINK(\"http://x\")", issuer: "+Evil, \"Inc\"")
        a.note = "line1\nline2"
        let b = makeAccount("@bob", issuer: "")
        let c = makeAccount("-x", issuer: "Tab\tFirst")
        let d = makeAccount("+491701234567", issuer: "Phone")
        let src = [a, b, c, d]
        let out = AccountExporter.applePasswordsCSV(src)
        let rows = try CSV.parse(String(decoding: out.data, as: UTF8.self))
        #expect(rows.count == 5 && rows[0].count == 6)
        #expect(rows[1][0] == "+Evil, \"Inc\"" && rows[1][2] == "=HYPERLINK(\"http://x\")" && rows[1][4] == "line1\nline2")
        #expect(rows[2][0] == "@bob" && rows[2][2] == "")
        #expect(rows[3][0] == "Tab\tFirst" && rows[3][2] == "-x")
        #expect(rows[4][0] == "Phone" && rows[4][2] == "+491701234567")
        // URL/Password are empty and the OTPAuth cell is a link.
        for row in rows.dropFirst() {
            #expect(row[1].isEmpty && row[3].isEmpty && row[5].hasPrefix("otpauth://totp?secret="))
        }
        // Round trip through the importer: issuer and name come back unchanged.
        let r = try imported(out.data)
        #expect(r.accounts[0].issuer == "+Evil, \"Inc\"" && r.accounts[0].name == "=HYPERLINK(\"http://x\")")
        #expect(r.accounts[2].issuer == "Tab\tFirst" && r.accounts[2].name == "-x")
        #expect(r.accounts[3].issuer == "Phone" && r.accounts[3].name == "+491701234567")
    }

    @Test func invalidAccountsAreReportedNotChanged() throws {
        var bad = makeAccount("bad", issuer: "X")
        bad.digits = 9
        var empty = makeAccount("empty", issuer: "Y")
        empty.secret = Data()
        let good = makeAccount("good", issuer: "Z")
        for out in [AccountExporter.otpauthList([bad, empty, good]), AccountExporter.applePasswordsCSV([bad, empty, good]),
                    try AccountExporter.aegisJSON([bad, empty, good], groups: [])] {
            #expect(out.exportedCount == 1)
            #expect(out.skipped == [ExportSkippedEntry(label: "X (bad)", reason: .invalidAccount), ExportSkippedEntry(label: "Y (empty)", reason: .invalidAccount)])
        }
    }

    @Test func emptyExports() throws {
        #expect(AccountExporter.otpauthList([]).data.isEmpty)
        #expect(String(decoding: AccountExporter.applePasswordsCSV([]).data, as: UTF8.self) == "Title,URL,Username,Password,Notes,OTPAuth\n")
        #expect(try AccountExporter.aegisJSON([], groups: []).exportedCount == 0)
    }

    @Test func privateFileIsOwnerOnlyEvenWhenOverwriting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macauth-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("export.txt")
        func mode() throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1 }
        try PrivateFile.write(Data("first".utf8), to: url)
        #expect(try mode() == 0o600)
        // An existing, more open file is narrowed and truncated.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try PrivateFile.write(Data("2".utf8), to: url)
        #expect(try mode() == 0o600 && Data(contentsOf: url) == Data("2".utf8))
        #expect(throws: BackupError.self) { try PrivateFile.write(Data(), to: dir.appendingPathComponent("missing/x.txt")) }
    }
}
