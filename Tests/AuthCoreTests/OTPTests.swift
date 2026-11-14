import Foundation
import Testing
@testable import AuthCore

struct OTPTests {
    static let secrets: [OTPAlgorithm: String] = [
        .sha1: "12345678901234567890",
        .sha256: "12345678901234567890123456789012",
        .sha512: "1234567890123456789012345678901234567890123456789012345678901234",
    ]

    // RFC 6238 appendix B, all times, 8 digits.
    static let rfc6238: [(Int, OTPAlgorithm, String)] = [
        (59, .sha1, "94287082"), (59, .sha256, "46119246"), (59, .sha512, "90693936"),
        (1_111_111_109, .sha1, "07081804"), (1_111_111_109, .sha256, "68084774"), (1_111_111_109, .sha512, "25091201"),
        (1_111_111_111, .sha1, "14050471"), (1_111_111_111, .sha256, "67062674"), (1_111_111_111, .sha512, "99943326"),
        (1_234_567_890, .sha1, "89005924"), (1_234_567_890, .sha256, "91819424"), (1_234_567_890, .sha512, "93441116"),
        (2_000_000_000, .sha1, "69279037"), (2_000_000_000, .sha256, "90698825"), (2_000_000_000, .sha512, "38618901"),
        (20_000_000_000, .sha1, "65353130"), (20_000_000_000, .sha256, "77737706"), (20_000_000_000, .sha512, "47863826"),
    ]

    @Test(arguments: rfc6238)
    func rfc6238Vectors(_ vector: (Int, OTPAlgorithm, String)) throws {
        let (time, algorithm, expected) = vector
        let code = try OTP.totp(secret: Data(Self.secrets[algorithm]!.utf8), at: Date(timeIntervalSince1970: TimeInterval(time)),
                                period: 30, algorithm: algorithm, digits: 8)
        #expect(code == expected)
    }

    static let rfc4226 = ["755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489"]

    @Test(arguments: Array(rfc4226.enumerated()))
    func rfc4226Vectors(_ vector: (Int, String)) throws {
        let code = try OTP.hotp(secret: Data("12345678901234567890".utf8), counter: UInt64(vector.0))
        #expect(code == vector.1)
    }

    @Test func sixDigitTotpKeepsLeadingZeros() throws {
        // RFC 6238 T=1111111109 gives 07081804 with 8 digits, so the 6-digit code starts with 0.
        let code = try OTP.totp(secret: Data("12345678901234567890".utf8), at: Date(timeIntervalSince1970: 1_111_111_109))
        #expect(code == "081804")
    }

    @Test func remainingSecondsAndCounter() {
        #expect(OTP.remainingSeconds(at: Date(timeIntervalSince1970: 0), period: 30) == 30)
        #expect(OTP.remainingSeconds(at: Date(timeIntervalSince1970: 29.9), period: 30) == 1)
        #expect(OTP.remainingSeconds(at: Date(timeIntervalSince1970: 30), period: 30) == 30)
        #expect(OTP.remainingSeconds(at: Date(timeIntervalSince1970: 59), period: 30) == 1)
        #expect(OTP.counter(at: Date(timeIntervalSince1970: 59), period: 30) == 1)
        #expect(OTP.remainingSeconds(at: Date(timeIntervalSince1970: 100), period: 60) == 20)
    }

    @Test func hostileDatesDoNotCrash() {
        #expect(OTP.counter(at: Date(timeIntervalSince1970: -5), period: 30) == 0)
        #expect(OTP.counter(at: Date(timeIntervalSince1970: .infinity), period: 30) == 0)
        #expect(OTP.counter(at: Date(timeIntervalSince1970: .nan), period: 30) == 0)
        #expect(OTP.counter(at: Date(timeIntervalSince1970: 1e300), period: 30) > 0)
        #expect(OTP.remainingSeconds(at: Date(timeIntervalSince1970: 1e300), period: 30) >= 1)
    }

    @Test func parameterValidation() {
        let secret = Data("12345678901234567890".utf8)
        #expect(throws: OTPError.emptySecret) { try OTP.hotp(secret: Data(), counter: 0) }
        #expect(throws: OTPError.invalidDigits(5)) { try OTP.hotp(secret: secret, counter: 0, digits: 5) }
        #expect(throws: OTPError.invalidDigits(9)) { try OTP.hotp(secret: secret, counter: 0, digits: 9) }
        #expect(throws: OTPError.invalidPeriod(14)) { try OTP.totp(secret: secret, at: Date(), period: 14) }
        #expect(throws: OTPError.invalidPeriod(121)) { try OTP.totp(secret: secret, at: Date(), period: 121) }
        #expect(throws: OTPError.invalidPeriod(0)) { try OTP.totp(secret: secret, at: Date(), period: 0) }
    }

    @Test func accountCodeNextCodeAndHOTPCounter() throws {
        let totp = makeAccount()
        let t = Date(timeIntervalSince1970: 59)
        #expect(try totp.code(at: t) == "287082")          // counter 1
        #expect(try totp.nextCode(at: t) == "359152")      // counter 2
        #expect(totp.remainingSeconds(at: t) == 1)
        var hotp = makeAccount(kind: .hotp, counter: 0)
        #expect(try hotp.code(at: t) == "755224")
        #expect(try hotp.nextCode(at: t) == "287082")
        #expect(hotp.remainingSeconds(at: t) == 0)
        hotp.advanceCounter()
        #expect(try hotp.code(at: t) == "287082")
        let overflow = makeAccount(kind: .hotp, counter: .max)
        #expect(throws: Never.self) { try overflow.nextCode(at: t) }
    }

    @Test func grouping() {
        #expect(OTP.grouped("482913") == "482 913")
        #expect(OTP.grouped("12345678") == "1234 5678")
        #expect(OTP.grouped("1234567") == "123 4567")
        #expect(OTP.grouped("123") == "123")
    }
}
