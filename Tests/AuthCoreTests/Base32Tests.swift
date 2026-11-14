import Foundation
import Testing
@testable import AuthCore

struct Base32Tests {
    static let vectors: [(String, String)] = [
        ("", ""), ("f", "MY======"), ("fo", "MZXQ===="), ("foo", "MZXW6==="),
        ("foob", "MZXW6YQ="), ("fooba", "MZXW6YTB"), ("foobar", "MZXW6YTBOI======"),
    ]

    @Test(arguments: vectors)
    func rfc4648Vectors(_ vector: (String, String)) throws {
        let (plain, encoded) = vector
        #expect(Base32.encode(Data(plain.utf8), padding: true) == encoded)
        #expect(Base32.encode(Data(plain.utf8)) == encoded.replacingOccurrences(of: "=", with: ""))
        #expect(try Base32.decode(encoded) == Data(plain.utf8))
    }

    @Test func toleranceForCaseWhitespaceDashesAndPadding() throws {
        let expected = Data("foobar".utf8)
        #expect(try Base32.decode("mzxw6ytboi") == expected)
        #expect(try Base32.decode("MZXW 6YTB OI") == expected)
        #expect(try Base32.decode("MZXW-6YTB-OI") == expected)
        #expect(try Base32.decode("  mzxw\t6ytb\noi  ") == expected)
        #expect(try Base32.decode("MZXW6YTBOI") == expected)
        #expect(try Base32.decode("MZXW6YTBOI======") == expected)
    }

    @Test func rejectsInvalidInput() {
        #expect(throws: Base32Error.invalidCharacter) { try Base32.decode("MZXW1YTB") }   // 1 is not in the alphabet
        #expect(throws: Base32Error.invalidCharacter) { try Base32.decode("MZXW8YTB") }
        #expect(throws: Base32Error.invalidCharacter) { try Base32.decode("MZXW!YTB") }
        #expect(throws: Base32Error.invalidCharacter) { try Base32.decode("MZXWÄYTB") }
        #expect(throws: Base32Error.invalidCharacter) { try Base32.decode("MZ==XW6Y") }   // data after padding
        #expect(throws: Base32Error.invalidLength) { try Base32.decode("M") }
        #expect(throws: Base32Error.invalidLength) { try Base32.decode("MZX") }
        #expect(throws: Base32Error.tooLong) { try Base32.decode(String(repeating: "A", count: 9000)) }
    }

    @Test func roundTripAllLengths() throws {
        for length in 0..<70 {
            let data = Data((0..<length).map { UInt8(($0 * 37 + 11) & 0xFF) })
            #expect(try Base32.decode(Base32.encode(data)) == data)
        }
    }
}
