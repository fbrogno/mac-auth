import Foundation
import Testing
@testable import AuthCore

struct MigrationTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    // Hand-built protobuf (see below), independent of AuthCore's writer.
    // A: 2 accounts (alice: SHA1/6/TOTP with "Issuer:name"; bob: SHA256/8/HOTP counter 5), batch 2 of 3 (index 1),
    //    negative batch id, unknown fields at top level (varint 20, fixed64 21, fixed32 22) and inside an entry
    //    (varint 15, length-delimited 9).
    static let fixtureA = "CkcKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEhlFeGFtcGxlOmFsaWNlQGV4YW1wbGUuY29tGgdFeGFtcGxlIAEoATACeKwCSgJ6egoxCiBhYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5ejAxMjM0NRIDYm9iGgAgAigCMAE4BRABGAMgASjr5ZDF//////8BoAEHqQEBAQEBAQEBAbUBAgICAg=="
    // B: no batch info; one MD5 entry (must be skipped) and one SHA512 entry.
    static let fixtureB = "CiEKEEpCU1dZM0RQRUhQSzNQWFASAXgaBFNraXAgBCgBMAIKHAoFAQIDBAUSB01haWw6bWUaBE1haWwgAygBMAIQAQ=="
    // C: exactly what the writer must produce for alice with batch id -42, 1 of 1.
    static let fixtureC = "CjgKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEhFhbGljZUBleGFtcGxlLmNvbRoHRXhhbXBsZSABKAEwAhABGAEgACjW//////////8B"

    @Test func readsFixtureA() throws {
        let batch = try MigrationCodec.parse(payload: Data(base64Encoded: Self.fixtureA)!, now: now)
        #expect(batch.accounts.count == 2)
        #expect(batch.version == 1 && batch.batchSize == 3 && batch.batchIndex == 1 && batch.batchID == -123_456_789)
        #expect(batch.skipped.isEmpty)
        let alice = batch.accounts[0]
        #expect(alice.issuer == "Example" && alice.name == "alice@example.com")   // "Example:" prefix stripped
        #expect(alice.secret == Data("12345678901234567890".utf8))
        #expect(alice.algorithm == .sha1 && alice.digits == 6 && alice.kind == .totp)
        let bob = batch.accounts[1]
        #expect(bob.issuer == "" && bob.name == "bob")
        #expect(bob.secret == Data("abcdefghijklmnopqrstuvwxyz012345".utf8))
        #expect(bob.algorithm == .sha256 && bob.digits == 8 && bob.kind == .hotp && bob.counter == 5)
    }

    @Test func readsFixtureBSkippingMD5() throws {
        let batch = try MigrationCodec.parse(payload: Data(base64Encoded: Self.fixtureB)!, now: now)
        #expect(batch.accounts.count == 1)
        #expect(batch.skipped == ["Skip (x)"])
        #expect(batch.batchSize == 1 && batch.batchIndex == 0)
        #expect(batch.accounts[0].algorithm == .sha512 && batch.accounts[0].issuer == "Mail" && batch.accounts[0].name == "me")
    }

    @Test func parsesURIWithPercentEncodedData() throws {
        let encoded = Self.fixtureA.replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "/", with: "%2F")
            .replacingOccurrences(of: "=", with: "%3D")
        let batch = try MigrationCodec.parse(uri: "otpauth-migration://offline?data=\(encoded)", now: now)
        #expect(batch.accounts.count == 2)
        // Raw (unescaped) base64 and missing padding are tolerated as well.
        let raw = try MigrationCodec.parse(uri: " otpauth-migration://offline?data=\(Self.fixtureA.replacingOccurrences(of: "=", with: ""))\n", now: now)
        #expect(raw.accounts.count == 2)
    }

    @Test func writerMatchesHandBuiltBytes() throws {
        let alice = makeAccount()
        let bytes = try MigrationCodec.payload(for: [alice], batchSize: 1, batchIndex: 0, batchID: -42)
        #expect(bytes == Data(base64Encoded: Self.fixtureC)!)
    }

    @Test func roundTrip() throws {
        let accounts = [makeAccount(), makeAccount("bob ö", issuer: "Büro", secret: "abcdefghijklmnopqrstuvwxyz012345",
                                                   algorithm: .sha512, digits: 8, kind: .hotp, counter: UInt64.max)]
        let uris = try MigrationCodec.uris(for: accounts, batchID: 77)
        #expect(uris.count == 1)
        let batch = try MigrationCodec.parse(uri: uris[0], now: now)
        #expect(batch.batchID == 77 && batch.batchSize == 1)
        #expect(batch.accounts.count == 2)
        for (a, b) in zip(accounts, batch.accounts) {
            #expect(a.isDuplicate(of: b))
            #expect(a.issuer == b.issuer && a.name == b.name && a.counter == b.counter)
        }
    }

    @Test func writerSplitsIntoBatchesOfTen() throws {
        let accounts = (0..<25).map { makeAccount("user\($0)", secret: "secret-\($0)-padpadpad") }
        let uris = try MigrationCodec.uris(for: accounts, batchID: -5)
        #expect(uris.count == 3)
        var collector = MigrationBatchCollector()
        for uri in uris { collector.add(try MigrationCodec.parse(uri: uri)) }
        #expect(collector.isComplete)
        #expect(collector.accounts.map(\.name) == accounts.map(\.name))
        #expect(try MigrationCodec.uris(for: []).isEmpty)
    }

    @Test func writerRejectsAccountsGoogleCannotRepresent() {
        #expect(throws: MigrationError.unsupportedForExport("Example (alice@example.com)")) {
            try MigrationCodec.uris(for: [makeAccount(digits: 7)])
        }
    }

    @Test func rejectsMalformedAndTruncatedInput() throws {
        let full = [UInt8](Data(base64Encoded: Self.fixtureA)!)
        // Cutting inside the trailing fixed32 field must fail.
        #expect(throws: MigrationError.malformedProtobuf) { try MigrationCodec.parse(payload: Data(full.dropLast(1))) }
        #expect(throws: MigrationError.malformedProtobuf) { try MigrationCodec.parse(payload: Data(full.prefix(30))) }
        // Every prefix: either parses or throws, never crashes.
        for n in 0..<full.count { _ = try? MigrationCodec.parse(payload: Data(full.prefix(n))) }
        // Length longer than the data, overlong varints, field number 0, groups, wrong wire type.
        #expect(throws: MigrationError.malformedProtobuf) { try MigrationCodec.parse(payload: Data([0x0A, 0x7F, 0x01])) }
        #expect(throws: MigrationError.malformedProtobuf) { try MigrationCodec.parse(payload: Data([0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])) }
        #expect(throws: MigrationError.malformedProtobuf) { try MigrationCodec.parse(payload: Data(repeating: 0x80, count: 12)) }
        #expect(throws: MigrationError.malformedProtobuf) { try MigrationCodec.parse(payload: Data([0x00, 0x01])) }
        #expect(throws: MigrationError.malformedProtobuf) { try MigrationCodec.parse(payload: Data([0x0B, 0x0C])) }
        #expect(throws: MigrationError.malformedProtobuf) { try MigrationCodec.parse(payload: Data([0x08, 0x01])) }   // field 1 as varint
        #expect(throws: MigrationError.inconsistentBatch) { try MigrationCodec.parse(payload: Data([0x18, 0x02, 0x20, 0x05])) } // index 5 of 2
    }

    @Test func fuzzNeverCrashes() {
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
        let seed = [UInt8](Data(base64Encoded: Self.fixtureA)!)
        for _ in 0..<3000 {
            var bytes = seed
            for _ in 0..<(1 + Int(next()) % 6) { bytes[Int(next()) % bytes.count] = next() }
            if next() % 3 == 0 { bytes.removeLast(Int(next()) % bytes.count) }
            _ = try? MigrationCodec.parse(payload: Data(bytes))
        }
        for _ in 0..<1000 {
            _ = try? MigrationCodec.parse(payload: Data((0..<Int(next())).map { _ in next() }))
        }
    }

    @Test func rejectsBadURIs() {
        #expect(throws: MigrationError.notMigrationURI) { try MigrationCodec.parse(uri: "otpauth://totp/x?secret=AAAA") }
        #expect(throws: MigrationError.missingData) { try MigrationCodec.parse(uri: "otpauth-migration://offline") }
        #expect(throws: MigrationError.missingData) { try MigrationCodec.parse(uri: "otpauth-migration://offline?data=") }
        #expect(throws: MigrationError.invalidBase64) { try MigrationCodec.parse(uri: "otpauth-migration://offline?data=!!!!") }
        #expect(throws: MigrationError.tooLarge) {
            try MigrationCodec.parse(uri: "otpauth-migration://offline?data=" + String(repeating: "A", count: 400_000))
        }
        #expect(throws: MigrationError.tooLarge) { try MigrationCodec.parse(payload: Data(count: 300_000)) }
    }

    @Test func limitsNumberOfAccounts() {
        var w = ProtoWriter()
        for _ in 0...Limits.maxMigrationAccounts {
            var p = ProtoWriter()
            p.bytes(1, [1, 2, 3])
            w.bytes(1, p.bytes)
        }
        #expect(throws: MigrationError.tooManyAccounts) { try MigrationCodec.parse(payload: Data(w.bytes)) }
    }

    @Test func collectorCountsAndIgnoresDuplicates() throws {
        func code(index: Int, size: Int = 3, id: Int32 = 9, name: String) throws -> MigrationBatch {
            let bytes = try MigrationCodec.payload(for: [makeAccount(name, secret: "secret-\(name)-padpadpad")],
                                                   batchSize: size, batchIndex: index, batchID: id)
            return try MigrationCodec.parse(payload: bytes)
        }
        var c = MigrationBatchCollector()
        #expect(c.expectedCount == nil && !c.isComplete && c.scannedCount == 0)
        #expect(c.add(try code(index: 1, name: "b")) == .added)
        #expect(c.scannedCount == 1 && c.expectedCount == 3 && c.missingIndexes == [0, 2])
        #expect(c.add(try code(index: 1, name: "b")) == .duplicate)
        #expect(c.scannedCount == 1)
        #expect(c.add(try code(index: 0, size: 3, id: 10, name: "other")) == .otherExport)
        #expect(c.add(try code(index: 0, size: 4, name: "other")) == .otherExport)
        #expect(c.add(try code(index: 2, name: "c")) == .added)
        #expect(!c.isComplete)
        #expect(c.add(try code(index: 0, name: "a")) == .added)
        #expect(c.isComplete && c.scannedCount == 3 && c.missingIndexes.isEmpty)
        #expect(c.accounts.map(\.name) == ["a", "b", "c"])   // QR order, not scan order
        c.reset()
        #expect(c.scannedCount == 0 && c.expectedCount == nil)

        // A single-code export is complete at once.
        var single = MigrationBatchCollector()
        single.add(try MigrationCodec.parse(payload: Data(base64Encoded: Self.fixtureB)!))
        #expect(single.isComplete)
    }
}
