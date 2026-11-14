import Foundation

/// RFC 4648 Base32. Decoding ignores case, spaces, dashes and padding.
public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    public static func encode(_ data: Data, padding: Bool = false) -> String {
        var out: [UInt8] = []
        out.reserveCapacity((data.count + 4) / 5 * 8)
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 0x1F)])
                bits -= 5
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        if bits > 0 {
            out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)])
        }
        if padding {
            while out.count % 8 != 0 { out.append(UInt8(ascii: "=")) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func decode(_ string: String) throws -> Data {
        guard string.utf8.count <= Limits.maxBase32InputBytes else { throw Base32Error.tooLong }
        var out = Data()
        var buffer: UInt32 = 0
        var bits = 0
        var symbols = 0
        var sawPadding = false
        for b in string.utf8 {
            switch b {
            case 0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: "-"):
                continue
            case UInt8(ascii: "="):
                sawPadding = true
                continue
            default:
                break
            }
            if sawPadding { throw Base32Error.invalidCharacter }
            let value: UInt8
            switch b {
            case 65...90: value = b - 65
            case 97...122: value = b - 97
            case 50...55: value = b - 50 + 26
            default: throw Base32Error.invalidCharacter
            }
            symbols += 1
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> UInt32(bits - 8)) & 0xFF))
                bits -= 8
                buffer &= (1 << UInt32(bits)) - 1
            }
        }
        // 1, 3 and 6 trailing symbols cannot come from whole bytes.
        switch symbols % 8 {
        case 1, 3, 6: throw Base32Error.invalidLength
        default: return out
        }
    }
}
