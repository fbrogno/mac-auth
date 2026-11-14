import Foundation
import Testing
@testable import AuthCore

struct OTPAuthTests {
    // "12345678901234567890" in Base32
    static let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func issuerInLabelOnly() throws {
        let a = try OTPAuthURI.parse("otpauth://totp/Example:alice@example.com?secret=\(Self.secret)", now: now)
        #expect(a.issuer == "Example")
        #expect(a.name == "alice@example.com")
        #expect(a.secret == Data("12345678901234567890".utf8))
        #expect(a.algorithm == .sha1 && a.digits == 6 && a.period == 30 && a.kind == .totp)
        #expect(a.createdAt == now)
    }

    @Test func issuerParameterWinsAndLabelPrefixIsStripped() throws {
        let a = try OTPAuthURI.parse("otpauth://totp/Old:alice?secret=\(Self.secret)&issuer=New", now: now)
        #expect(a.issuer == "New")
        #expect(a.name == "alice")
        let b = try OTPAuthURI.parse("otpauth://totp/alice?secret=\(Self.secret)&issuer=Only", now: now)
        #expect(b.issuer == "Only" && b.name == "alice")
    }

    @Test func percentEncodingAndUmlauts() throws {
        let a = try OTPAuthURI.parse("otpauth://totp/B%C3%BCro%20%C3%84rger:j%C3%BCrgen%40example.com?secret=\(Self.secret)&issuer=B%C3%BCro%20%C3%84rger", now: now)
        #expect(a.issuer == "Büro Ärger")
        #expect(a.name == "jürgen@example.com")
        let b = try OTPAuthURI.parse("otpauth://totp/Example%3Aalice?secret=\(Self.secret)", now: now)
        #expect(b.issuer == "Example" && b.name == "alice")
        let c = try OTPAuthURI.parse("otpauth://totp/Müller:Jörg?secret=\(Self.secret)", now: now)   // raw umlauts
        #expect(c.issuer == "Müller" && c.name == "Jörg")
        let d = try OTPAuthURI.parse("OTPAUTH://TOTP/x?SECRET=\(Self.secret.lowercased())", now: now)
        #expect(d.name == "x" && d.secret.count == 20)
    }

    @Test func optionalFieldsAndKinds() throws {
        let a = try OTPAuthURI.parse("otpauth://totp/x?secret=\(Self.secret)&algorithm=sha512&digits=8&period=60", now: now)
        #expect(a.algorithm == .sha512 && a.digits == 8 && a.period == 60)
        let h = try OTPAuthURI.parse("otpauth://hotp/x?secret=\(Self.secret)&counter=18446744073709551615", now: now)
        #expect(h.kind == .hotp && h.counter == UInt64.max)
        let noLabel = try OTPAuthURI.parse("otpauth://totp?secret=\(Self.secret)", now: now)
        #expect(noLabel.name == "" && noLabel.issuer == "")
        let padded = try OTPAuthURI.parse("otpauth://totp/x?secret=gezd%20gnbv-GY3T====", now: now)
        #expect(padded.secret == Data("1234567".utf8))
    }

    @Test func rejectsBadInput() {
        #expect(throws: OTPAuthError.notOTPAuthURI) { try OTPAuthURI.parse("https://example.com") }
        #expect(throws: OTPAuthError.missingSecret) { try OTPAuthURI.parse("otpauth://totp/x") }
        #expect(throws: OTPAuthError.missingSecret) { try OTPAuthURI.parse("otpauth://totp/x?secret=") }
        #expect(throws: OTPAuthError.invalidSecret) { try OTPAuthURI.parse("otpauth://totp/x?secret=!!!!") }
        #expect(throws: OTPAuthError.invalidSecret) { try OTPAuthURI.parse("otpauth://totp/x?secret=\(String(repeating: "A", count: 600))") }
        #expect(throws: OTPAuthError.unsupportedType("steam")) { try OTPAuthURI.parse("otpauth://steam/x?secret=\(Self.secret)") }
        #expect(throws: OTPAuthError.invalidParameter("digits")) { try OTPAuthURI.parse("otpauth://totp/x?secret=\(Self.secret)&digits=4") }
        #expect(throws: OTPAuthError.invalidParameter("algorithm")) { try OTPAuthURI.parse("otpauth://totp/x?secret=\(Self.secret)&algorithm=MD5") }
        #expect(throws: OTPAuthError.invalidParameter("period")) { try OTPAuthURI.parse("otpauth://totp/x?secret=\(Self.secret)&period=0") }
        #expect(throws: OTPAuthError.invalidParameter("counter")) { try OTPAuthURI.parse("otpauth://hotp/x?secret=\(Self.secret)&counter=-1") }
        #expect(throws: OTPAuthError.malformedURI) { try OTPAuthURI.parse("otpauth://totp/x%ZZ?secret=\(Self.secret)") }
        #expect(throws: OTPAuthError.malformedURI) { try OTPAuthURI.parse("otpauth://totp/%FF%FE?secret=\(Self.secret)") }
        #expect(throws: OTPAuthError.tooLong) { try OTPAuthURI.parse("otpauth://totp/" + String(repeating: "a", count: 9000)) }
    }

    @Test func serialiseAndParseRoundTrip() throws {
        let originals = [
            makeAccount(),
            makeAccount("jürgen@example.com", issuer: "Büro & Ärger: Test", secret: "abc", algorithm: .sha512, digits: 8, period: 45),
            makeAccount("x y", issuer: "", kind: .hotp, counter: 99),
        ]
        for original in originals {
            let uri = OTPAuthURI.string(for: original)
            #expect(uri.hasPrefix("otpauth://\(original.kind.rawValue)/"))
            let parsed = try OTPAuthURI.parse(uri, now: now)
            #expect(parsed.issuer == original.issuer)
            #expect(parsed.name == original.name)
            #expect(parsed.secret == original.secret)
            #expect(parsed.algorithm == original.algorithm && parsed.digits == original.digits)
            #expect(parsed.kind == original.kind && parsed.counter == original.counter)
            if original.kind == .totp { #expect(parsed.period == original.period) }
        }
    }

    @Test func serialisedFormIsStable() {
        let uri = OTPAuthURI.string(for: makeAccount())
        #expect(uri == "otpauth://totp/Example:alice%40example.com?secret=\(Self.secret)&issuer=Example&algorithm=SHA1&digits=6&period=30")
    }
}
