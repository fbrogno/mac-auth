import CryptoKit
import Foundation

public enum OTPAlgorithm: String, Codable, Sendable, CaseIterable {
    case sha1, sha256, sha512
}

public enum OTPKind: String, Codable, Sendable, CaseIterable {
    case totp, hotp
}

/// RFC 4226 (HOTP) and RFC 6238 (TOTP). Pure functions of their inputs; no clock, locale or time zone involved.
public enum OTP {
    public static let allowedDigits = 6...8
    public static let allowedPeriods = 15...120
    public static let defaultPeriod = 30

    public static func hotp(secret: Data, counter: UInt64, algorithm: OTPAlgorithm = .sha1, digits: Int = 6) throws -> String {
        guard !secret.isEmpty else { throw OTPError.emptySecret }
        guard allowedDigits.contains(digits) else { throw OTPError.invalidDigits(digits) }
        var message = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { message[7 - i] = UInt8((counter >> UInt64(8 * i)) & 0xFF) }
        let key = SymmetricKey(data: secret)
        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let binary = (UInt32(mac[offset] & 0x7F) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let number = String(binary % modulus)
        return String(repeating: "0", count: digits - number.count) + number
    }

    public static func totp(secret: Data, at date: Date, period: Int = defaultPeriod,
                            algorithm: OTPAlgorithm = .sha1, digits: Int = 6) throws -> String {
        guard allowedPeriods.contains(period) else { throw OTPError.invalidPeriod(period) }
        return try hotp(secret: secret, counter: counter(at: date, period: period), algorithm: algorithm, digits: digits)
    }

    /// Time step for a date (Unix time / period). Dates before 1970 or non-finite dates count as 0.
    public static func counter(at date: Date, period: Int) -> UInt64 {
        guard period > 0 else { return 0 }
        return UInt64(unixSeconds(date)) / UInt64(period)
    }

    /// Seconds until the current code changes, `1...period`.
    public static func remainingSeconds(at date: Date, period: Int = defaultPeriod) -> Int {
        guard period > 0 else { return 0 }
        return period - Int(unixSeconds(date) % Int64(period))
    }

    /// Splits a code for display: `482913` becomes `482 913`, `12345678` becomes `1234 5678`.
    public static func grouped(_ code: String) -> String {
        let split: Int
        switch code.count {
        case 6: split = 3
        case 7: split = 3
        case 8: split = 4
        default: return code
        }
        let i = code.index(code.startIndex, offsetBy: split)
        return code[..<i] + " " + code[i...]
    }

    private static func unixSeconds(_ date: Date) -> Int64 {
        let t = date.timeIntervalSince1970
        guard t.isFinite, t > 0 else { return 0 }
        return t >= 9e18 ? Int64.max : Int64(t)
    }
}

extension Account {
    /// Current code: TOTP for `date`, HOTP for the stored counter.
    public func code(at date: Date) throws -> String {
        switch kind {
        case .totp: try OTP.totp(secret: secret, at: date, period: period, algorithm: algorithm, digits: digits)
        case .hotp: try OTP.hotp(secret: secret, counter: counter, algorithm: algorithm, digits: digits)
        }
    }

    /// TOTP: the code of the next period. HOTP: the code for `counter + 1` (does not change the counter).
    public func nextCode(at date: Date) throws -> String {
        switch kind {
        case .totp:
            try OTP.totp(secret: secret, at: date.addingTimeInterval(TimeInterval(period)), period: period, algorithm: algorithm, digits: digits)
        case .hotp:
            try OTP.hotp(secret: secret, counter: counter &+ 1, algorithm: algorithm, digits: digits)
        }
    }

    /// Seconds left for the current TOTP code; 0 for HOTP.
    public func remainingSeconds(at date: Date) -> Int {
        kind == .totp ? OTP.remainingSeconds(at: date, period: period) : 0
    }

    /// HOTP: move to the next counter value (call after the user consumed a code).
    public mutating func advanceCounter() {
        counter = counter &+ 1
    }
}
