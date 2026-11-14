import Foundation

/// Minimal protobuf wire-format reader. Every read is bounds-checked; malformed input throws.
struct ProtoReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { position >= bytes.count }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, to: 70, by: 7) {
            guard position < bytes.count else { throw MigrationError.malformedProtobuf }
            let b = bytes[position]
            position += 1
            if shift == 63 && b > 1 { throw MigrationError.malformedProtobuf }
            result |= UInt64(b & 0x7F) << UInt64(shift)
            if b & 0x80 == 0 { return result }
        }
        throw MigrationError.malformedProtobuf
    }

    /// Next field header, or nil at the end of input.
    mutating func readTag() throws -> (field: Int, wire: Int)? {
        if isAtEnd { return nil }
        let tag = try readVarint()
        let field = tag >> 3
        guard field >= 1, field <= 0x1FFF_FFFF else { throw MigrationError.malformedProtobuf }
        return (Int(field), Int(tag & 7))
    }

    mutating func readBytes() throws -> [UInt8] {
        let length = try readVarint()
        guard length <= UInt64(bytes.count - position) else { throw MigrationError.malformedProtobuf }
        let end = position + Int(length)
        defer { position = end }
        return Array(bytes[position..<end])
    }

    mutating func skip(wire: Int) throws {
        switch wire {
        case 0: _ = try readVarint()
        case 1: try advance(8)
        case 2: _ = try readBytes()
        case 5: try advance(4)
        default: throw MigrationError.malformedProtobuf
        }
    }

    private mutating func advance(_ n: Int) throws {
        guard n <= bytes.count - position else { throw MigrationError.malformedProtobuf }
        position += n
    }
}

struct ProtoWriter {
    private(set) var bytes: [UInt8] = []

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    mutating func tag(_ field: Int, wire: Int) { varint(UInt64(field << 3 | wire)) }

    mutating func uint(_ field: Int, _ value: UInt64) {
        tag(field, wire: 0)
        varint(value)
    }

    /// int32 fields: negative values are sign-extended to 64 bits (10 bytes), as protobuf requires.
    mutating func int32(_ field: Int, _ value: Int32) {
        uint(field, UInt64(bitPattern: Int64(value)))
    }

    mutating func bytes(_ field: Int, _ value: [UInt8]) {
        tag(field, wire: 2)
        varint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    mutating func string(_ field: Int, _ value: String) { bytes(field, Array(value.utf8)) }
}
