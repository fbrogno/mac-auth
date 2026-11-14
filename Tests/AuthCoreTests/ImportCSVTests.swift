import Foundation
import Testing
@testable import AuthCore

struct ImportCSVTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    static let s1 = ImportTests.s1
    static let s2 = ImportTests.s2
    // Distinctive invented password that must never show up in any result.
    static let pw = "Pw-Sentinel-7Q9x!zK"

    func detect(_ text: String) throws -> ImportDetection { try ImportDetector.detect(Data(text.utf8), now: now) }
    func result(_ text: String) throws -> ImportResult {
        guard case .accounts(let r) = try detect(text) else { throw ImportError.unrecognizedFormat }
        return r
    }

    // MARK: CSV parser

    @Test func parserHandlesQuotingNewlinesAndLineEndings() throws {
        let text = "a,b,c\r\n\"x,1\",\"he said \"\"hi\"\"\",\"line1\nline2\"\r\n,,\r\nlast,\"\",z"
        let rows = try CSV.parse(text)
        #expect(rows == [["a", "b", "c"], ["x,1", "he said \"hi\"", "line1\nline2"], ["", "", ""], ["last", "", "z"]])
        #expect(try CSV.parse("a,b\n1,2\n") == [["a", "b"], ["1", "2"]])      // trailing newline, no phantom row
        #expect(try CSV.parse("a,b\r1,2\r") == [["a", "b"], ["1", "2"]])      // lone CR
        #expect(try CSV.parse("a,b\n\n\n1,2") == [["a", "b"], ["1", "2"]])    // blank lines
        #expect(try CSV.parse("a\"b,c") == [["a\"b", "c"]])                    // quote inside unquoted field is literal
    }

    @Test func detectorToleratesBOMBeforeCSVHeader() throws {
        let r = try result("\u{FEFF}name,totp\r\nA,\(Self.s1)\r\n")
        #expect(r.accounts.count == 1 && r.format == .genericCSV)
    }

    @Test func parserDropsUnkeptColumns() throws {
        let rows = try CSV.parse("t,p,o\nx,secretpw,y", keep: [0, 2])
        #expect(rows == [["t", "", "o"], ["x", "", "y"]])
    }

    @Test func parserRejectsHostileInput() {
        #expect(throws: ImportError.self) { try CSV.parse("a,b\n\"never closed,1\n2,3") }
        #expect(throws: ImportError.self) { try CSV.parse("a,\"b\"x\n") }
        let huge = "a,b\n" + String(repeating: "x", count: Limits.maxCSVFieldBytes + 1) + ",1\n"
        #expect(throws: ImportError.malformedCSV("Feld zu groß")) { try CSV.parse(huge) }
        let hugeQuoted = "a\n\"" + String(repeating: "x", count: Limits.maxCSVFieldBytes + 1) + "\"\n"
        #expect(throws: ImportError.self) { try CSV.parse(hugeQuoted) }
        let wide = (0...Limits.maxCSVColumns).map(String.init).joined(separator: ",")
        #expect(throws: ImportError.self) { try CSV.parse(wide) }
        let long = "a,b\n" + String(repeating: "1,2\n", count: Limits.maxCSVRows + 1)
        #expect(throws: ImportError.tooManyEntries) { try CSV.parse(long) }
    }

    // MARK: Apple Passwords

    var apple: String {
        "Title,URL,Username,Password,Notes,OTPAuth\r\n" +
        "Example,https://example.com,alice@example.com,\(Self.pw),,otpauth://totp?secret=\(Self.s1)&algorithm=SHA256&digits=8&period=60\r\n" +
        "Mail,https://mail.example,bob,\(Self.pw),\"note, with comma\",otpauth://totp/Mail:bob?secret=\(Self.s2)&issuer=Mail\r\n" +
        "NoCode,https://x.example,carl,\(Self.pw),,\r\n" +
        "NoCode2,https://y.example,dora,\(Self.pw),\r\n" +
        "Broken,https://z.example,eve,\(Self.pw),,otpauth://totp?secret=!!!\r\n" +
        "Steamy,,,\(Self.pw),,steam://\(Self.s1)\r\n" +
        "Hotp,,hank,\(Self.pw),,otpauth://hotp?secret=\(Self.s1)&counter=5\r\n"
    }

    @Test func readsApplePasswordsCSV() throws {
        let r = try result(apple)
        #expect(r.format == .applePasswordsCSV)
        #expect(r.accounts.count == 3)
        let a = r.accounts[0]
        #expect(a.issuer == "Example" && a.name == "alice@example.com" && a.algorithm == .sha256 && a.digits == 8 && a.period == 60)
        #expect(r.accounts[1].issuer == "Mail" && r.accounts[1].name == "bob")
        #expect(r.accounts[2].kind == .hotp && r.accounts[2].counter == 5 && r.accounts[2].name == "hank")
        #expect(r.rowsWithoutCode == 2)
        #expect(r.skipped == [SkippedEntry(label: "Broken (eve)", reason: .invalidSecret),
                              SkippedEntry(label: "Steamy", reason: .unsupportedType("steam"))])
    }

    @Test func passwordNeverAppearsAnywhere() throws {
        let r = try result(apple)
        var dumped = ""
        dump(r, to: &dumped)
        let all = [String(describing: r), dumped, String(reflecting: r.accounts), String(describing: r.skipped)]
        for text in all { #expect(!text.contains(Self.pw)) }
        // Also in errors thrown for hostile files that contain the password.
        let bad = "Title,URL,Username,Password,Notes,OTPAuth\nx,y,z,\(Self.pw),\"unterminated"
        do { _ = try detect(bad); Issue.record("expected an error") } catch {
            #expect(!String(describing: error).contains(Self.pw))
            #expect(!String(reflecting: error).contains(Self.pw))
            #expect(!(error.localizedDescription).contains(Self.pw))
        }
        // A password column that is huge must not even be scanned into a result.
        let hugePw = "Title,URL,Username,Password,Notes,OTPAuth\nx,y,z,\(String(repeating: "P", count: Limits.maxCSVFieldBytes + 5)),,otpauth://totp?secret=\(Self.s1)\n"
        #expect(throws: ImportError.self) { try detect(hugePw) }
    }

    // MARK: Generic CSV

    @Test func readsBitwardenCSV() throws {
        let text = "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n" +
            ",,login,GitHub,,,0,https://github.com,alice,\(Self.pw),otpauth://totp/GitHub:alice?secret=\(Self.s1)&issuer=GitHub\n" +
            ",,login,Bare,,,0,,bob,\(Self.pw),\(Self.s2.lowercased())\n" +
            ",,note,Just a note,text,,0,,,,\n"
        let r = try result(text)
        #expect(r.format == .genericCSV)
        #expect(r.accounts.count == 2 && r.rowsWithoutCode == 1)
        #expect(r.accounts[0].issuer == "GitHub" && r.accounts[0].name == "alice")
        let bare = r.accounts[1]
        #expect(bare.issuer == "Bare" && bare.name == "bob" && bare.algorithm == .sha1 && bare.digits == 6 && bare.period == 30 && bare.secret.count == 20)
    }

    @Test func readsOnePasswordAndProtonColumns() throws {
        let onePassword = "Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\nAcme,https://acme.example,zed,\(Self.pw),otpauth://totp/?secret=\(Self.s1),0,0,,\n"
        let r1 = try result(onePassword)
        #expect(r1.accounts.first?.issuer == "Acme" && r1.accounts.first?.name == "zed")
        let proton = "type,name,url,email,username,password,note,totp,createTime,modifyTime,vault\nlogin,Proton Thing,,a@b.example,,\(Self.pw),,\(Self.s1),1,2,Personal\n"
        let r2 = try result(proton)
        #expect(r2.accounts.count == 1 && r2.accounts[0].issuer == "Proton Thing")
        // Proton keeps the login in `email` when `username` is empty; the importer reads the first username-like column only.
        #expect(!String(describing: r2).contains(Self.pw))
    }

    @Test func genericCSVWithoutOTPColumnIsNotRecognised() {
        #expect(throws: ImportError.unrecognizedFormat) { try detect("name,age\nx,1\n") }
        #expect(throws: ImportError.unrecognizedFormat) { try detect("justonecolumn\nvalue\n") }
    }

    @Test func duplicateHeaderNamesAreRefused() {
        #expect(throws: ImportError.malformedCSV("doppelte Spaltennamen")) {
            try detect("name,totp,TOTP\nx,\(Self.s1),\(Self.s2)\n")
        }
    }

    @Test func shortAndLongRowsAreTolerated() throws {
        let r = try result("name,totp,extra\nshort\nfine,\(Self.s1)\nlong,\(Self.s2),a,b,c\n")
        #expect(r.accounts.map(\.issuer) == ["fine", "long"] && r.rowsWithoutCode == 1)
    }

    @Test func badSecretsInGenericCSVAreListedWithoutSecret() throws {
        let r = try result("name,username,totp\nA,u,not base32 !!\nB,,otpauth://totp/x?secret=\(Self.s1)&digits=9\nC,,otpauth-migration://offline?data=abc\n")
        #expect(r.accounts.isEmpty)
        #expect(r.skipped.map(\.label) == ["A (u)", "B", "C"])
        #expect(r.skipped.map(\.reason) == [.invalidSecret, .invalidParameter("digits"), .invalidSecret])
    }

    @Test func csvDoesNotBreakOtpauthLists() throws {
        // A line list whose first line happens to contain a comma is still a line list.
        let r = try result("notes, with comma\notpauth://totp/A:b?secret=\(Self.s1)\n")
        #expect(r.format == .otpauthLines && r.accounts.count == 1)
    }

    @Test func binaryGarbageThrowsTypedError() {
        let junk = Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) })
        #expect(throws: ImportError.self) { try ImportDetector.detect(junk) }
        #expect(throws: ImportError.self) { try ImportDetector.detect(Data([0, 0, 0, 0x2C, 0, 0x22, 0x22])) }
    }

    // MARK: Bitwarden JSON

    @Test func readsBitwardenJSON() throws {
        let json = """
        {"encrypted":false,"folders":[{"id":"f1","name":"Work"}],"items":[
         {"id":"1","folderId":"f1","type":1,"name":"GitHub","notes":null,"login":{"username":"alice","password":"\(Self.pw)","totp":"otpauth://totp/GitHub:alice?secret=\(Self.s1)&issuer=GitHub&digits=8"}},
         {"id":"2","type":1,"name":"Bare","login":{"username":"bob","password":"\(Self.pw)","totp":"\(Self.s2)"}},
         {"id":"3","type":1,"name":"Game","login":{"username":"gamer","password":"\(Self.pw)","totp":"steam://\(Self.s1)"}},
         {"id":"4","type":1,"name":"NoTotp","login":{"username":"x","password":"\(Self.pw)","totp":null}},
         {"id":"5","type":2,"name":"A note","notes":"text","secureNote":{"type":0}},
         {"id":"6","type":1,"name":"Broken","login":{"username":"y","totp":"!!!"}}
        ]}
        """
        let r = try result(json)
        #expect(r.format == .bitwarden)
        #expect(r.accounts.count == 2 && r.rowsWithoutCode == 2)
        #expect(r.accounts[0].issuer == "GitHub" && r.accounts[0].name == "alice" && r.accounts[0].digits == 8)
        #expect(r.accounts[1].issuer == "Bare" && r.accounts[1].name == "bob" && r.accounts[1].period == 30)
        #expect(r.skipped == [SkippedEntry(label: "Game (gamer)", reason: .unsupportedType("steam")),
                              SkippedEntry(label: "Broken (y)", reason: .invalidSecret)])
        #expect(!String(describing: r).contains(Self.pw))
    }

    @Test func refusesEncryptedBitwarden() {
        let enc = #"{"encrypted":true,"encKeyValidation_DO_NOT_EDIT":"2.x|y|z","data":"2.a|b|c"}"#
        #expect(throws: ImportError.encryptedFile(.bitwarden)) { try detect(enc) }
        let pw = #"{"encrypted":true,"passwordProtected":true,"salt":"s","kdfType":0,"kdfIterations":600000,"data":"2.a|b|c"}"#
        #expect(throws: ImportError.encryptedFile(.bitwarden)) { try detect(pw) }
        #expect(throws: ImportError.encryptedFile(.bitwarden)) { try detect(#"{"passwordProtected":true,"items":[]}"#) }
    }

    @Test func bitwardenBogusItemsDoNotCrash() throws {
        let r = try result(#"{"items":[1,null,"x",{"login":5},{"login":{"totp":7}}]}"#)
        #expect(r.accounts.isEmpty && r.skipped.count == 3 && r.rowsWithoutCode == 2)
    }

    // MARK: andOTP

    @Test func readsAndOTPPlain() throws {
        let json = """
        [{"secret":"\(Self.s1)","issuer":"Example","label":"alice","digits":6,"type":"TOTP","algorithm":"SHA1","thumbnail":"Default","last_used":1,"used_frequency":0,"period":30,"tags":["a"]},
         {"secret":"\(Self.s2)","issuer":"","label":"bob","digits":8,"type":"HOTP","algorithm":"SHA512","counter":9,"tags":[]},
         {"secret":"\(Self.s1)","issuer":"Steam","label":"g","digits":5,"type":"STEAM","algorithm":"SHA1","period":30},
         {"secret":"\(Self.s1)","issuer":"M","label":"m","type":"MOTP","algorithm":"MD5"},
         {"secret":"\(Self.s1)","issuer":"H","label":"h","type":"HOTP","algorithm":"SHA1"}]
        """
        let r = try result(json)
        #expect(r.format == .andOTP && r.accounts.count == 2)
        #expect(r.accounts[0].issuer == "Example" && r.accounts[0].name == "alice")
        #expect(r.accounts[1].kind == .hotp && r.accounts[1].counter == 9 && r.accounts[1].digits == 8 && r.accounts[1].algorithm == .sha512)
        #expect(r.skipped.map(\.reason) == [.unsupportedType("steam"), .unsupportedType("motp"), .invalidParameter("counter")])
        #expect(throws: ImportError.unrecognizedFormat) { try detect("[]") }
        #expect(throws: ImportError.unrecognizedFormat) { try detect(#"[{"foo":1}]"#) }
        #expect(throws: ImportError.unrecognizedFormat) { try detect("[1,2") }
    }
}
