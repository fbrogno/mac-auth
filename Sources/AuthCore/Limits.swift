import Foundation

/// Upper bounds for foreign input (QR codes, pasted links, backup and vault files).
enum Limits {
    static let maxSecretBytes = 256
    static let maxTextBytes = 1024
    static let maxOTPAuthURIBytes = 8 * 1024
    static let maxBase32InputBytes = 8 * 1024
    static let maxMigrationPayloadBytes = 256 * 1024
    static let maxMigrationAccounts = 500
    static let maxFileBytes = 32 * 1024 * 1024
    static let maxEnvelopeFields = 16
    static let maxEnvelopeFieldBytes = 8 * 1024
    /// CSV imports: rows (including the header), columns per row and bytes per field.
    static let maxCSVRows = 10_000
    static let maxCSVColumns = 64
    static let maxCSVFieldBytes = 16 * 1024
}

enum Base64Util {
    /// Decodes standard or URL-safe Base64, with or without padding.
    static func decodeFlexible(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s.removeAll(where: { $0 == "\n" || $0 == "\r" || $0 == " " })
        let remainder = s.count % 4
        if remainder == 1 { return nil }
        if remainder != 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}

enum PercentCoding {
    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)

    /// Percent-encodes everything except RFC 3986 unreserved characters.
    static func encode(_ string: String) -> String {
        var out = ""
        for byte in string.utf8 {
            if unreserved.contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out += "%" + String(format: "%02X", byte)
            }
        }
        return out
    }

    /// Decodes %XX sequences; `+` stays literal. Returns nil for bad escapes or invalid UTF-8.
    static func decode(_ string: Substring) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.utf8.count)
        var it = string.utf8.makeIterator()
        while let b = it.next() {
            if b == UInt8(ascii: "%") {
                guard let h = it.next(), let l = it.next(), let hv = hex(h), let lv = hex(l) else { return nil }
                bytes.append(hv << 4 | lv)
            } else {
                bytes.append(b)
            }
        }
        return String(data: Data(bytes), encoding: .utf8)
    }

    private static func hex(_ b: UInt8) -> UInt8? {
        switch b {
        case 48...57: return b - 48
        case 65...70: return b - 55
        case 97...102: return b - 87
        default: return nil
        }
    }
}
